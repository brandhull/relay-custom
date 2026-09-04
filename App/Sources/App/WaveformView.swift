import SwiftUI

/// Static waveform rendered from evenly-sampled bar heights (pseudo-random,
/// seeded by recording id so it stays stable across redraws).
struct WaveformView: View {
    let samples: [CGFloat]
    var progress: CGFloat = 0 // 0...1, portion played/selected
    var color: Color = Theme.accent
    var inactiveColor: Color = Theme.muted.opacity(0.35)

    var body: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2
            let count = max(1, Int(geo.size.width / (barWidth + spacing)))
            let bars = resample(samples, to: count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(CGFloat(index) / CGFloat(max(count - 1, 1)) <= progress ? color : inactiveColor)
                        .frame(width: barWidth, height: max(3, height * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resample(_ input: [CGFloat], to count: Int) -> [CGFloat] {
        guard !input.isEmpty else { return Array(repeating: 0.15, count: count) }
        return (0..<count).map { i in
            let srcIndex = Int(CGFloat(i) / CGFloat(count) * CGFloat(input.count))
            return input[min(srcIndex, input.count - 1)]
        }
    }

    static func placeholderSamples(seed: Int, count: Int = 120) -> [CGFloat] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in CGFloat.random(in: 0.1...1.0, using: &generator) }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
