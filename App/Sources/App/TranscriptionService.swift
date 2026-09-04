import Foundation
import Speech
import AVFoundation

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case noResult

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Speech recognition permission was denied. Enable it in Settings > Privacy > Speech Recognition."
        case .recognizerUnavailable: return "On-device speech recognition isn't available right now."
        case .noResult: return "Couldn't transcribe that recording."
        }
    }
}

enum TranscriptionService {
    /// On-device speech recognition silently gives up and only returns the
    /// last recognized fragment on longer files — well past this point it's
    /// unreliable in one request. Chunking below this keeps each request
    /// comfortably inside what the recognizer handles reliably.
    private static let maxChunkDuration: TimeInterval = 50

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes fully on-device — nothing about the audio leaves the
    /// phone. Splits longer recordings into chunks under the recognizer's
    /// reliable duration ceiling and stitches the results together, since a
    /// single request over ~a minute tends to silently drop everything but
    /// the last recognized fragment.
    static func transcribe(fileURL: URL, onProgress: ((String) -> Void)? = nil) async throws -> String {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds

        guard duration > maxChunkDuration else {
            return try await transcribeChunk(fileURL: fileURL)
        }

        let chunkCount = Int((duration / maxChunkDuration).rounded(.up))
        var transcripts: [String] = []
        var tempFiles: [URL] = []
        defer { for url in tempFiles { try? FileManager.default.removeItem(at: url) } }

        for index in 0..<chunkCount {
            onProgress?("Transcribing part \(index + 1) of \(chunkCount)…")
            let start = Double(index) * maxChunkDuration
            let end = min(start + maxChunkDuration, duration)
            let chunkURL = try await exportChunk(asset: asset, start: start, end: end)
            tempFiles.append(chunkURL)
            let text = try await transcribeChunk(fileURL: chunkURL)
            if !text.isEmpty { transcripts.append(text) }
        }

        let combined = transcripts.joined(separator: " ")
        guard !combined.isEmpty else { throw TranscriptionError.noResult }
        return combined
    }

    private static func exportChunk(asset: AVURLAsset, start: TimeInterval, end: TimeInterval) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.recognizerUnavailable
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        await exportSession.export()
        if let error = exportSession.error { throw error }
        return outputURL
    }

    private static func transcribeChunk(fileURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}
