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

    /// `SFSpeechURLRecognitionRequest` (handing the recognizer a file
    /// directly) has a well-known on-device truncation bug: it silently
    /// gives up partway through and reports whatever partial hypothesis it
    /// had as the final result — no error, no signal anything was lost.
    ///
    /// `SFSpeechAudioBufferRecognitionRequest` is built around exactly one
    /// well-tested feeding pattern: a live tap on an `AVAudioEngine` node,
    /// the same mechanism used for live mic dictation. Two earlier attempts
    /// tried to approximate that by hand — appending decoded buffers as fast
    /// as possible, then with a manual sleep between each — and both still
    /// produced garbled, incomplete transcripts, because a hand-timed
    /// approximation isn't the same as the engine's actual real-time render
    /// clock. This plays the chunk back (muted) through a player node and
    /// taps its real output, which gives the recognizer the exact cadence
    /// it expects with no timing guesswork.
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
        request.shouldReportPartialResults = false

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        return try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
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
                    finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                finish(.success(result.bestTranscription.formattedString))
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
