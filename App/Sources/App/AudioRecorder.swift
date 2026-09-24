import Foundation
import AVFoundation
import Combine

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
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    /// The tap fires on a real-time audio thread, not the main actor —
    /// gating the (synchronous, in-order) buffer write on this plain flag
    /// avoids hopping to the main actor per-buffer, which risks writes
    /// landing out of order under load. Mirrors `isPaused` whenever it
    /// changes; only this flag is read by the tap itself.
    nonisolated(unsafe) private var captureIsPaused = false
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
    /// Records via AVAudioEngine, bound to the picked device when one is
    /// set — scoped to this app's own audio unit, unlike overwriting the
    /// system's default input (which would affect every other app until
    /// changed back). Falls back to the system default when no device is
    /// picked. The output format matches the input node's own native
    /// format/channel count rather than a hardcoded 44.1kHz mono — a
    /// mismatch against a device's real format (e.g. a virtual device
    /// running at 48kHz) was a likely second contributor to a silent
    /// recording alongside picking the wrong device outright.
    private func startEngineRecording(to url: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let uid = selectedInputDeviceUID,
           let device = AudioInputDeviceLister.availableInputDevices().first(where: { $0.uid == uid }),
           let audioUnit = inputNode.audioUnit {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                print("Failed to select input device (status \(status)); falling back to system default")
            }
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: min(inputFormat.channelCount, 2),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: outputSettings)

        captureIsPaused = false
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.captureIsPaused else { return }
            // Write happens synchronously, in-order, on this same real-time
            // thread every time — no actor hop here, since hopping per
            // buffer risks writes landing out of order under load. The
            // meter level is purely cosmetic, so it's fine to hop for that.
            try? file.write(from: buffer)
            let level = Self.rmsLevel(from: buffer)
            Task { @MainActor in
                self.meterLevel = level
            }
        }

        try engine.start()

        self.engine = engine
        self.audioFile = file
    }

    private nonisolated static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(frameCount))
        return min(max(rms * 4, 0), 1)
    }

    private func stopEngineRecording() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
    }
    #endif

    func pause() {
        recorder?.pause()
        #if os(macOS)
        captureIsPaused = true
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
        captureIsPaused = false
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
