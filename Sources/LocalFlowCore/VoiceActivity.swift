import Foundation

public struct SpeechBounds: Sendable {
    public var hasSpeech: Bool
    public var startSample: Int
    public var endSample: Int
    public var speechSeconds: TimeInterval
}

public enum VoiceActivity {
    /// Trims leading/trailing silence using short-window RMS energy.
    /// This is intentionally small and deterministic; a CoreML Silero VAD can replace it later.
    public static func trim(
        samples: [Float],
        sampleRate: Double = 16_000,
        threshold: Float = 0.012,
        paddingSeconds: TimeInterval = 0.12
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let bounds = speechBounds(samples: samples, sampleRate: sampleRate, threshold: threshold)
        guard bounds.hasSpeech else { return [] }
        let padding = Int(paddingSeconds * sampleRate)
        let start = max(0, bounds.startSample - padding)
        let end = min(samples.count, bounds.endSample + padding)
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }

    public static func speechBounds(
        samples: [Float],
        sampleRate: Double = 16_000,
        threshold: Float = 0.012
    ) -> SpeechBounds {
        let window = max(1, Int(sampleRate * 0.02)) // 20 ms
        let hop = max(1, Int(sampleRate * 0.01))    // 10 ms
        var firstActive = -1
        var lastActive = -1
        var activeWindows = 0
        var index = 0

        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) {
                let sample = samples[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(window))
            if rms >= threshold {
                activeWindows += 1
                if firstActive < 0 { firstActive = index }
                lastActive = index + window
            }
            index += hop
        }

        guard firstActive >= 0 else {
            return SpeechBounds(hasSpeech: false, startSample: 0, endSample: 0, speechSeconds: 0)
        }
        return SpeechBounds(
            hasSpeech: true,
            startSample: firstActive,
            endSample: lastActive,
            speechSeconds: TimeInterval(lastActive - firstActive) / sampleRate
        )
    }

    public static func hasSpeech(samples: [Float], sampleRate: Double = 16_000, threshold: Float = 0.012) -> Bool {
        speechBounds(samples: samples, sampleRate: sampleRate, threshold: threshold).hasSpeech
    }
}
