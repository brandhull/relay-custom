import AppIntents

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Opens Relay and starts recording.")
    // Mic capture needs the app in the foreground — this can't run silently
    // in the background the way Import can.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = AudioRecorder.shared
        guard await recorder.requestPermission() else {
            throw RelayIntentError.microphonePermissionDenied
        }
        if !recorder.isRecording {
            recorder.startRecording()
        }
        return .result()
    }
}

enum RelayIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case microphonePermissionDenied
    case recordingNotFound
    case audioAlreadyRemoved
    case importFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .microphonePermissionDenied:
            return "Relay needs microphone access — enable it in Settings."
        case .recordingNotFound:
            return "Couldn't find that recording."
        case .audioAlreadyRemoved:
            return "This recording's local audio was already removed after upload."
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}
