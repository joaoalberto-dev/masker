import XCTest
@testable import MaskerCore

final class MicrophoneLevelTests: XCTestCase {
    func testMicrophoneGainMultipliesAndClampsTheLevel() {
        XCTAssertEqual(MicrophoneLevel.adjusted(0.4, gain: 2, softness: 0, previous: 0), 0.8)
        XCTAssertEqual(MicrophoneLevel.adjusted(0.8, gain: 2, softness: 0, previous: 0), 1)
    }

    func testMicrophoneSoftnessSmoothsAbruptLevelChanges() {
        XCTAssertEqual(MicrophoneLevel.adjusted(1, gain: 1, softness: 0.75, previous: 0), 0.25)
    }

    func testFloatPeakUsesLargestAbsoluteSample() {
        let samples: [Float] = [-0.2, 0.65, -0.4]

        XCTAssertEqual(samples.withUnsafeBufferPointer { MicrophoneLevel.peak(in: $0) }, 0.65)
    }

    func testFloatPeakIsClampedToOne() {
        let samples: [Float] = [0.3, -1.4]

        XCTAssertEqual(samples.withUnsafeBufferPointer { MicrophoneLevel.peak(in: $0) }, 1)
    }

    func testIntegerPeakNormalizesAndHandlesMinimumSample() {
        let samples: [Int16] = [Int16.min, 1200]

        XCTAssertEqual(samples.withUnsafeBufferPointer { MicrophoneLevel.peak(in: $0) }, 1)
    }

    func testEmptySamplesHaveNoLevel() {
        let samples: [Float] = []

        XCTAssertNil(samples.withUnsafeBufferPointer { MicrophoneLevel.peak(in: $0) })
    }
}
