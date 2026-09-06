import Foundation

enum CraftPublishError: LocalizedError {
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .missingConfig: return "Add your Craft API URL and pick a folder in Settings first."
        }
    }
}

/// Transcribes a recording on-device, summarizes instead if it runs over the
/// configured threshold and Apple Intelligence summarization is available,
/// then creates a new document for it in the configured Craft folder. Shared
/// by EditRecordingView's manual "Transcribe" action and PublishView's
/// auto-send-on-publish toggle, so the transcribe/summarize/create-document
/// logic exists in exactly one place.
enum CraftPublisher {
    /// Returns "Transcript" or "Summary" — whichever was actually sent.
    @MainActor
    static func send(
        recording: Recording,
        settings: AppSettings,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        guard settings.hasCraftConfig, let craftURL = URL(string: settings.craftAPIURL) else {
            throw CraftPublishError.missingConfig
        }

        onProgress?("Requesting permission…")
        guard await TranscriptionService.requestAuthorization() else {
            throw TranscriptionError.permissionDenied
        }

        onProgress?("Transcribing…")
        let transcript = try await TranscriptionService.transcribe(fileURL: recording.fileURL, onProgress: onProgress)

        var content = transcript
        var label = "Transcript"
        if recording.duration > Double(settings.summarizeThresholdMinutes * 60) {
            if #available(iOS 26.0, *), SummarizationService.isAvailable() {
                onProgress?("Summarizing…")
                content = try await SummarizationService.summarize(transcript)
                label = "Summary"
            }
        } else if settings.cleanupPunctuationEnabled {
            if #available(iOS 26.0, *), SummarizationService.isAvailable() {
                onProgress?("Cleaning up punctuation…")
                content = try await SummarizationService.cleanupPunctuation(transcript)
            }
        }

        onProgress?("Sending to Craft…")
        let craft = CraftAPI(baseURL: craftURL)
        let title = recording.episode.title.isEmpty
            ? "Recording \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))"
            : recording.episode.title
        let documentId = try await craft.createDocument(title: title, folderId: settings.craftFolderId)
        try await craft.insertMarkdown(content, intoDocument: documentId)

        return label
    }
}
