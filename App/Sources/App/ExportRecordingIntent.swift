import AppIntents
import Foundation

/// Returns a recording's audio file back out to Shortcuts — e.g. to pipe
/// into "Save to Files," AirDrop, or attach to an email. Runs entirely on
/// file I/O, no mic, so it works in the background.
struct ExportRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Recording"
    static var description = IntentDescription("Returns a recording's audio file from Relay's Library.")
    static var openAppWhenRun = false

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let stored = RecordingStore.shared.recordings.first(where: { $0.id == recording.id }) else {
            throw RelayIntentError.recordingNotFound
        }
        guard !stored.audioRemovedLocally else {
            throw RelayIntentError.audioAlreadyRemoved
        }
        let data = try Data(contentsOf: stored.fileURL)
        let file = IntentFile(data: data, filename: stored.fileName)
        return .result(value: file)
    }
}
