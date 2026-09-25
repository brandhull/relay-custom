import Foundation
import AVFoundation
import Combine
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    /// Single shared instance — see RecordingStore.shared for why AppIntents
    /// need this instead of relying on SwiftUI environment injection alone.
    static let shared = AudioRecorder()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var currentInputName: String = "Built-in Microphone"
    @Published var meterLevel: Float = 0 // 0...1
    /// Timestamps flagged during the recording in progress. Copied onto the
    /// `Recording` when it's created in `RecordView`, then cleared here for
    /// the next take.
    @Published private(set) var pendingFlags: [TimeInterval] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private(set) var outputURL: URL?

    #if os(macOS)
    /// The CoreAudio device UID to record from, or nil for "System Default".
    /// Local to this Mac — not synced via AppSettings' iCloud store, since a
    /// specific device UID is meaningless on another machine (or on iOS).
    @Published var selectedInputDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedInputDeviceUID, forKey: "macSelectedInputDeviceUID") }
    }
    /// Raw CoreAudio IOProc, not AVAudioEngine — see MacRecordingWriter's
    /// doc comment for why (AVAudioEngine.inputNode redirected to a
    /// runtime-picked device silently produced empty/near-silent
    /// recordings here, a known rough edge with a matching writeup in the
    /// Maverick app's own MeetingRecorder.swift).
    private var ioProcID: AudioDeviceIOProcID?
    private var activeDeviceID: AudioDeviceID?
    private var writer: MacRecordingWriter?
    #endif

    override init() {
        super.init()
        #if os(macOS)
        selectedInputDeviceUID = UserDefaults.standard.string(forKey: "macSelectedInputDeviceUID")
        #endif
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        #endif
    }

    func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        #else
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        #endif
    }

    /// Prefers an external input (USB-C wired mic, or a wireless receiver like a
    /// lav/handheld system) over the built-in mic whenever one is connected.
    /// No-ops the category/activation reset while a recording is already in
    /// progress — this is now the one shared recorder instance, so views
    /// like Settings that call this on every appearance (to refresh the mic
    /// list) shouldn't be able to re-activate/re-route the session out from
    /// under an active recording just by being visible.
    ///
    /// macOS has no `AVAudioSession` — recording there just uses whatever
    /// input is selected in System Settings → Sound (v1 scope; no auto-
    /// preferring on Mac yet). It DOES reflect the actual current input's
    /// name, though — unlike iOS's built-in mic, a Mac's default input can
    /// easily be a virtual/routing device (Loopback, Audio Hijack, etc.)
    /// instead of a real microphone, and recording from an unrouted virtual
    /// device silently produces a valid-looking file with no audio in it.
    /// Surfacing the real name lets that be caught before recording, not
    /// discovered after.
    func configureSessionPreferringExternalMic() {
        #if os(iOS)
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setActive(true)
        refreshPreferredInput()
        #else
        refreshCurrentInputName()
        #endif
    }

    #if os(macOS)
    /// Reflects whichever device recording will actually use — the picked
    /// device if one is set, otherwise the system default.
    func refreshCurrentInputName() {
        if let uid = selectedInputDeviceUID,
           let device = AudioInputDeviceLister.availableInputDevices().first(where: { $0.uid == uid }) {
            currentInputName = device.name
        } else if let name = AVCaptureDevice.default(for: .audio)?.localizedName {
            currentInputName = name
        }
    }
    #endif

    #if os(iOS)
    /// Re-derives the current input, preferring an external mic. Deliberately
    /// doesn't touch session category/activation — safe to call from a route
    /// change notification, which can fire mid-transition (e.g. right as a
    /// Bluetooth mic connects) while `currentRoute` is transiently empty.
    /// Falls back to keeping the last known-good name rather than ever
    /// showing "No Input" for a route that's just mid-negotiation.
    private func refreshPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        if let inputs = session.availableInputs {
            let external = inputs.first { port in
                port.portType == .usbAudio ||
                port.portType == .headsetMic ||
                port.portType == .bluetoothHFP ||
                port.portType == .bluetoothLE
            }
            if let external {
                try? session.setPreferredInput(external)
                currentInputName = external.portName
                return
            } else if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
                currentInputName = builtIn.portName
                return
            }
        }
        if let routeInput = session.currentRoute.inputs.first {
            currentInputName = routeInput.portName
        }
    }

    /// AVAudioSession posts route-change notifications off the main thread,
    /// but this class's state is @MainActor — hop explicitly rather than
    /// relying on @objc to bypass isolation checking, which previously let
    /// `currentInputName` get mutated from a background thread and land
    /// inconsistently in the UI.
    @objc private func routeChanged() {
        Task { @MainActor [weak self] in
            self?.refreshPreferredInput()
        }
    }

    /// A call, Siri, an alarm, or another app taking over audio all raise
    /// this — without handling it, an in-progress recording just silently
    /// stops writing while the UI keeps showing "Recording…". On `.began`
    /// we mirror it into a normal pause so the UI reflects reality and the
    /// user can resume deliberately once the interruption clears; we don't
    /// auto-resume on `.ended` even when the system flags it as safe to,
    /// since resuming a recording without the user noticing is worse than
    /// requiring one extra tap.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        guard type == .began else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }
            self.pause()
        }
    }
    #endif

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    #if os(iOS)
    func availableInputs() -> [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    func selectInput(_ port: AVAudioSessionPortDescription) {
        try? AVAudioSession.sharedInstance().setPreferredInput(port)
        currentInputName = port.portName
    }
    #endif

    /// Marks the current moment as a flag. Only meaningful while actively
    /// recording (not paused) — the elapsed clock is frozen while paused, so
    /// flagging then would just duplicate whatever the last real flag was.
    func addFlag() {
        guard isRecording, !isPaused else { return }
        pendingFlags.append(elapsed)
    }

    /// Hands back the flags captured during this take and resets for the
    /// next one.
    func takePendingFlags() -> [TimeInterval] {
        defer { pendingFlags = [] }
        return pendingFlags
    }

    func startRecording() {
        configureSessionPreferringExternalMic()

        let fileName = "\(UUID().uuidString).m4a"
        let url = Recording.directory.appendingPathComponent(fileName)
        outputURL = url

        #if os(macOS)
        do {
            try startEngineRecording(to: url)
            isRecording = true
            isPaused = false
            accumulated = 0
            pendingFlags = []
            startDate = Date()
            startTimer()
        } catch {
            print("Recording failed to start: \(error)")
        }
        #else
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.delegate = self
            recorder?.record()
            isRecording = true
            isPaused = false
            accumulated = 0
            pendingFlags = []
            startDate = Date()
            startTimer()
        } catch {
            print("Recording failed to start: \(error)")
        }
        #endif
    }

    #if os(macOS)
    /// Records via a raw CoreAudio IOProc bound directly to the picked
    /// device (or the system default), not AVAudioEngine — see this
    /// property section's doc comment for why. The actual PCM format is
    /// derived from the device's own first real callback (in
    /// `MacRecordingWriter`), not assumed ahead of time from a node's
    /// cached format, which is the specific thing that was unreliable.
    private func startEngineRecording(to url: URL) throws {
        let deviceID: AudioDeviceID
        if let uid = selectedInputDeviceUID,
           let device = AudioInputDeviceLister.availableInputDevices().first(where: { $0.uid == uid }) {
            deviceID = device.id
        } else {
            deviceID = try Self.defaultInputDeviceID()
        }

        let sampleRate = Self.nominalSampleRate(of: deviceID) ?? 48000
        let writer = MacRecordingWriter(fileURL: url, sampleRate: sampleRate)

        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, deviceID, nil) { _, inInputData, _, _, _ in
            writer.consume(inInputData)
        }
        guard createStatus == noErr, let newIOProcID else {
            throw NSError(domain: "AudioRecorder", code: Int(createStatus), userInfo: [NSLocalizedDescriptionKey: "Couldn't create audio tap (status \(createStatus))"])
        }

        let startStatus = AudioDeviceStart(deviceID, newIOProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, newIOProcID)
            throw NSError(domain: "AudioRecorder", code: Int(startStatus), userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording device (status \(startStatus))"])
        }

        self.ioProcID = newIOProcID
        self.activeDeviceID = deviceID
        self.writer = writer
    }

    private func stopEngineRecording() {
        if let ioProcID, let activeDeviceID {
            AudioDeviceStop(activeDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(activeDeviceID, ioProcID)
        }
        ioProcID = nil
        activeDeviceID = nil
        writer = nil
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else {
            throw NSError(domain: "AudioRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn't find the default input device"])
        }
        return deviceID
    }

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : nil
    }
    #endif

    func pause() {
        recorder?.pause()
        #if os(macOS)
        // Stops the IOProc without destroying it or closing the file —
        // resuming just restarts the same IOProc, appending to the same
        // still-open file (no silence gap, no new file).
        if let ioProcID, let activeDeviceID {
            AudioDeviceStop(activeDeviceID, ioProcID)
        }
        #endif
        isPaused = true
        accumulated += Date().timeIntervalSince(startDate ?? Date())
        stopTimer()
    }

    func resume() {
        #if os(iOS)
        // An interruption (or backgrounding) can deactivate the session out
        // from under us; re-activate explicitly rather than assuming
        // `record()` alone will do it.
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        #if os(macOS)
        if let ioProcID, let activeDeviceID {
            AudioDeviceStart(activeDeviceID, ioProcID)
        }
        #endif
        recorder?.record()
        isPaused = false
        startDate = Date()
        startTimer()
    }

    /// Stops recording and returns the final duration.
    func stop() -> TimeInterval {
        if !isPaused {
            accumulated += Date().timeIntervalSince(startDate ?? Date())
        }
        recorder?.stop()
        #if os(macOS)
        stopEngineRecording()
        #endif
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRecording = false
        isPaused = false
        stopTimer()
        let final = accumulated
        elapsed = 0
        accumulated = 0
        return final
    }

    /// Stops recording and discards it entirely — deletes the audio file
    /// rather than handing back a duration for the caller to save. Used by
    /// the Record screen's cancel button.
    func cancel() {
        recorder?.stop()
        #if os(macOS)
        stopEngineRecording()
        #endif
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        isRecording = false
        isPaused = false
        stopTimer()
        elapsed = 0
        accumulated = 0
        outputURL = nil
        pendingFlags = []
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let live = self.isPaused ? 0 : Date().timeIntervalSince(self.startDate ?? Date())
                self.elapsed = self.accumulated + live
                self.recorder?.updateMeters()
                if let power = self.recorder?.averagePower(forChannel: 0) {
                    let normalized = pow(10, power / 20)
                    self.meterLevel = min(max(normalized, 0), 1)
                }
                #if os(macOS)
                if let writer = self.writer {
                    self.meterLevel = writer.currentLevel
                }
                #endif
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Recorder encode error: \(String(describing: error))")
    }
}
