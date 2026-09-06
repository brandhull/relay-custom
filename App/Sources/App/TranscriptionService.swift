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
    /// On-device speech recognition silently gives up and only returns a
    /// fragment of the audio when a single request runs long — and in
    /// practice that ceiling is lower and less predictable than it first
    /// looked: a 47-second recording sent as one unchunked request still
    /// truncated to a single sentence. There's no safe "this is short
    /// enough, skip chunking" threshold, so every recording — regardless of
    /// length — is always split into pieces at or under this duration.
    private static let maxChunkDuration: TimeInterval = 25

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes fully on-device — nothing about the audio leaves the
    /// phone. Always chunks (even short recordings) and stitches the
    /// results together, since on-device recognition has proven unreliable
    /// on a single request even well under a minute.
    static func transcribe(fileURL: URL, onProgress: ((String) -> Void)? = nil) async throws -> String {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds

        let chunkCount = max(1, Int((duration / maxChunkDuration).rounded(.up)))
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

        // File-based on-device recognition delivers `isFinal` once per
        // detected phrase/pause within the file, not once for the whole
        // request — treating the first `isFinal` as "done" silently drops
        // every segment after it. Instead, collect every final segment and
        // only resolve once no further segment has arrived for a beat.
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var segments: [String] = []
            var generation = 0

            func finish() {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: segments.joined(separator: " "))
            }

            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    if segments.isEmpty {
                        didResume = true
                        continuation.resume(throwing: error)
                    } else {
                        finish()
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                segments.append(result.bestTranscription.formattedString)
                generation += 1
                let thisGeneration = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard !didResume, thisGeneration == generation else { return }
                    finish()
                }
            }
        }
    }
}
