import XCTest
@testable import LocalFlowCore

final class VoiceActivityTests: XCTestCase {
    func testTrimsSilence() {
        var samples = [Float](repeating: 0, count: 1600) // 0.1s silence
        for i in 0..<3200 { samples.append(sin(Float(i) * 0.1) * 0.2) } // ~0.2s tone
        samples.append(contentsOf: [Float](repeating: 0, count: 1600))
        let trimmed = VoiceActivity.trim(samples: samples, threshold: 0.01)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThan(trimmed.count, samples.count)
    }

    func testNoSpeech() {
        let samples = [Float](repeating: 0, count: 16000)
        XCTAssertFalse(VoiceActivity.hasSpeech(samples: samples))
        XCTAssertTrue(VoiceActivity.trim(samples: samples).isEmpty)
    }
}
