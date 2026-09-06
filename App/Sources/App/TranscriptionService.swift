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

        // Splitting at a fixed `maxChunkDuration` and letting the remainder
        // trail off as its own tiny chunk (e.g. a 51s recording becoming
        // 25s/25s/1s) produces a near-empty, often mid-word final chunk.
        // Instead spread the recording evenly across however many chunks it
        // needs, so every chunk is a similar, reasonable length.
        let chunkCount = max(1, Int((duration / maxChunkDuration).rounded(.up)))
        let chunkDuration = duration / Double(chunkCount)
        var transcripts: [String] = []
        var tempFiles: [URL] = []
        defer { for url in tempFiles { try? FileManager.default.removeItem(at: url) } }

        for index in 0..<chunkCount {
            onProgress?("Transcribing part \(index + 1) of \(chunkCount)…")
            let start = Double(index) * chunkDuration
            let end = index == chunkCount - 1 ? duration : start + chunkDuration
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

    /// `SFSpeechURLRecognitionRequest` (handing the recognizer a file
    /// directly) has a well-known on-device truncation bug: it silently
    /// gives up partway through and reports whatever partial hypothesis it
    /// had as the final result — no error, no signal anything was lost.
    /// Feeding audio via a real `AVAudioEngine` tap (played back muted
    /// through a player node) rather than any hand-timed buffer loop rules
    /// out the *feeding mechanism* as the cause — every mechanism tried
    /// (raw file, dumped buffers, sleep-paced buffers, engine-tapped
    /// buffers) reproduced the exact same symptom: each chunk's returned
    /// text is only the *tail* of what it should contain, as if the
    /// consolidated final result regresses to a shorter version of what the
    /// recognizer had already produced. `shouldReportPartialResults = false`
    /// was the one setting never varied across those attempts — so instead
    /// of trusting the final result's own text, every result (partial and
    /// final) is tracked and the longest one seen is what's returned.
    private static func transcribeChunk(fileURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.recognizerUnavailable
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        return try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            var longestSoFar = ""
            func finish(_ result: Result<String, Error>) {
                guard !didFinish else { return }
                didFinish = true
                player.removeTap(onBus: 0)
                engine.stop()
                switch result {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    // If we'd already captured something before the error,
                    // prefer returning that over failing the whole chunk.
                    finish(longestSoFar.isEmpty ? .failure(error) : .success(longestSoFar))
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if text.count > longestSoFar.count { longestSoFar = text }
                if result.isFinal { finish(.success(longestSoFar)) }
            }

            // Tap the player's own bus (pre-mixer, pre-mute) so the
            // recognizer gets clean, full-volume samples driven by the
            // engine's real playback clock.
            player.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                request.append(buffer)
            }

            do {
                try engine.start()
            } catch {
                finish(.failure(error))
                return
            }

            player.scheduleFile(audioFile, at: nil) {
                request.endAudio()
            }
            player.play()
        }
    }
}
