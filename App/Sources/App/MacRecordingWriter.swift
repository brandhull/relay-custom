#if os(macOS)
import AVFoundation
import AudioToolbox

/// Builds the `AVAudioFile` lazily, on the first real audio callback, from
/// that callback's own `AudioBufferList` shape, rather than assuming the
/// format ahead of time from a node's cached value — adapted from the
/// Maverick app's `LazyPCMFileWriter` (`MeetingRecorder.swift`), whose own
/// doc comment explains why: redirecting `AVAudioEngine.inputNode` to a
/// runtime-picked device doesn't reliably refresh its cached format, which
/// silently produced empty/near-silent recordings here too. This runs
/// entirely on the realtime CoreAudio IOProc thread — deliberately not
/// actor-isolated, so the audio thread never has to hop or await.
///
/// Unlike Maverick (which mixes a stereo mic stream and a stereo
/// system-audio tap together), Relay only ever records one device, so this
/// mixes every channel the device provides down to mono — simpler, smaller
/// files, and consistent with what Relay's iOS recordings have always used.
final class MacRecordingWriter: @unchecked Sendable {
    let fileURL: URL
    private let sampleRate: Double
    private var format: AVAudioFormat?
    private var file: AVAudioFile?

    // `consume` runs on the realtime IOProc thread; `currentLevel` is
    // polled from the main actor on a timer — a plain lock, not actor
    // isolation, since the audio thread can never be made to `await`.
    private let levelLock = NSLock()
    private var _currentLevel: Float = 0
    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _currentLevel
    }

    init(fileURL: URL, sampleRate: Double) {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
    }

    func consume(_ inInputData: UnsafePointer<AudioBufferList>) {
        let listPointer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))

        if format == nil {
            guard let derived = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ) else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: derived.sampleRate,
                AVNumberOfChannelsKey: derived.channelCount,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            guard let newFile = try? AVAudioFile(
                forWriting: fileURL, settings: settings,
                commonFormat: derived.commonFormat, interleaved: derived.isInterleaved
            ) else { return }
            format = derived
            file = newFile
        }

        guard let format, let file,
              let buffer = Self.monoMixBuffer(from: listPointer, format: format) else { return }
        try? file.write(from: buffer)

        levelLock.lock()
        _currentLevel = Self.peakLevel(of: buffer)
        levelLock.unlock()
    }

    private static func monoMixBuffer(
        from streams: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let firstStream = streams.first, firstStream.mNumberChannels > 0,
              firstStream.mDataByteSize > 0 else { return nil }
        let frameCount = Int(firstStream.mDataByteSize)
            / (Int(firstStream.mNumberChannels) * MemoryLayout<Float>.size)
        guard frameCount > 0,
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let destinationChannel = destination.floatChannelData else { return nil }
        destination.frameLength = AVAudioFrameCount(frameCount)
        let out = destinationChannel[0]
        for frame in 0..<frameCount { out[frame] = 0 }

        for stream in streams {
            let channels = Int(stream.mNumberChannels)
            guard channels > 0, let sourceData = stream.mData else { continue }
            let source = sourceData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                var frameSum: Float = 0
                for channel in 0..<channels { frameSum += source[frame * channels + channel] }
                out[frame] += frameSum / Float(channels)
            }
        }
        for frame in 0..<frameCount {
            out[frame] = min(max(out[frame], -1), 1)
        }
        return destination
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = data[0]
        var peak: Float = 0
        for i in 0..<frameCount { peak = max(peak, abs(samples[i])) }
        return min(peak * 4, 1)
    }
}
#endif
