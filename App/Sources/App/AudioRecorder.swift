import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var currentInputName: String = "Built-in Microphone"
    @Published var meterLevel: Float = 0 // 0...1

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private(set) var outputURL: URL?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Prefers an external input (USB-C wired mic, or a wireless receiver like a
    /// lav/handheld system) over the built-in mic whenever one is connected.
    /// No-ops the category/activation reset while a recording is already in
    /// progress — this is now the one shared recorder instance, so views
    /// like Settings that call this on every appearance (to refresh the mic
    /// list) shouldn't be able to re-activate/re-route the session out from
    /// under an active recording just by being visible.
    func configureSessionPreferringExternalMic() {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setActive(true)
        refreshPreferredInput()
    }

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func availableInputs() -> [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    func selectInput(_ port: AVAudioSessionPortDescription) {
        try? AVAudioSession.sharedInstance().setPreferredInput(port)
        currentInputName = port.portName
    }

    func startRecording() {
        configureSessionPreferringExternalMic()

        let fileName = "\(UUID().uuidString).m4a"
        let url = Recording.directory.appendingPathComponent(fileName)
        outputURL = url

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
            startDate = Date()
            startTimer()
        } catch {
            print("Recording failed to start: \(error)")
        }
    }

    func pause() {
        recorder?.pause()
        isPaused = true
        accumulated += Date().timeIntervalSince(startDate ?? Date())
        stopTimer()
    }

    func resume() {
        // An interruption (or backgrounding) can deactivate the session out
        // from under us; re-activate explicitly rather than assuming
        // `record()` alone will do it.
        try? AVAudioSession.sharedInstance().setActive(true)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        isPaused = false
        stopTimer()
        let final = accumulated
        elapsed = 0
        accumulated = 0
        return final
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
