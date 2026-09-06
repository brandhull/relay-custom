import AppIntents
import AVFoundation
import Foundation

/// Bypasses the Record screen entirely — takes an audio file from anywhere
/// (Files, another app's share sheet, a Shortcuts automation) and drops it
/// straight into the Library as a new Recording. Pure file I/O + a store
/// update, no microphone involved, so this can run fully in the background.
struct ImportRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Import Recording"
    static var description = IntentDescription("Adds an audio file to Relay's Library.")
    static var openAppWhenRun = false

    @Parameter(title: "Audio File")
    var audioFile: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RecordingEntity> {
        let sourceExtension = (audioFile.filename as NSString).pathExtension
        let ext = sourceExtension.isEmpty ? "m4a" : sourceExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destinationURL = Recording.directory.appendingPathComponent(fileName)

        do {
            try audioFile.data.write(to: destinationURL)
        } catch {
            throw RelayIntentError.importFailed(error.localizedDescription)
        }

        let asset = AVURLAsset(url: destinationURL)
        let duration: TimeInterval
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            duration = 0
        }

        let title = (audioFile.filename as NSString).deletingPathExtension
        let recording = Recording(
            id: UUID(),
            fileName: fileName,
            createdAt: Date(),
            duration: duration,
            episode: EpisodeDraft(title: title.isEmpty ? "Imported Recording" : title)
        )
        RecordingStore.shared.add(recording)

        return .result(value: RecordingEntity(recording))
    }
}
