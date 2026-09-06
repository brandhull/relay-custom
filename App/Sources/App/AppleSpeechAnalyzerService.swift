import Foundation
import Speech
import AVFoundation

/// Wraps Apple's iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` — the
/// replacement for the old `SFSpeechRecognizer` line. Unlike the old API
/// (built around a live mic tap, forced into a batch-file role via chunking
/// and buffer-feeding workarounds — see `TranscriptionService`), this one
/// has a direct file-based entry point designed for exactly this use case,
/// so the whole recording goes through in one call with no manual chunking
/// and no chunk-boundary risk.
@available(iOS 26.0, *)
enum AppleSpeechAnalyzerService {
    private static let locale = Locale(identifier: "en-US")

    static func isAvailable() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    static func transcribe(fileURL: URL, onProgress: ((String) -> Void)? = nil) async throws -> String {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.recognizerUnavailable
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)

        // First use of a locale requires downloading Apple's on-device
        // model asset; already-installed locales return nil here and skip
        // straight to analysis.
        if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress?("Downloading speech model…")
            try await installRequest.downloadAndInstall()
        }

        onProgress?("Transcribing…")

        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )

        // With the plain `.transcription` preset (no `.volatileResults`),
        // each result is a distinct, already-finalized segment of the
        // timeline — not a growing cumulative hypothesis — so segments are
        // appended as they arrive, one per detected span, until the stream
        // completes (triggered by `finishAfterFile`).
        var fullText = ""
        for try await result in transcriber.results {
            fullText += String(result.text.characters)
        }

        withExtendedLifetime(analyzer) {}

        guard !fullText.isEmpty else { throw TranscriptionError.noResult }
        return fullText
    }
}
