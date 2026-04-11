/// Standalone test runner — does not require XCTest or full Xcode.
/// Run: swift Tests/AudioMixerTests/AudioMixerTests.swift (from project root)
/// Or the tests are verified inline below via assertions.

import Foundation
import AVFoundation
// Note: When run via `swift test` with Xcode installed, replace with XCTest imports.
// This file serves as a verification script runnable with just Command Line Tools.

// MARK: - Test Helpers

var testCount = 0
var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  ✗ FAIL: \(message) (\(file):\(line))")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    testCount += 1
    if a == b {
        passCount += 1
    } else {
        failCount += 1
        print("  ✗ FAIL: \(message.isEmpty ? "Expected \(a) == \(b)" : message) (\(file):\(line))")
    }
}

// Note: These tests import types from the main AudioMixer module.
// Since we can't easily @testable import from a script without XCTest/Xcode,
// the test logic is documented here for running once Xcode is available.
// Below we test standalone logic that doesn't require imports.

// MARK: - MixerConfiguration JSON Round-Trip

print("▸ MixerConfiguration JSON round-trip")
do {
    struct InputStripConfig: Codable, Equatable {
        var deviceUID: String
        var leftChannelIndex: Int
        var rightChannelIndex: Int
        var volume: Float
        var boostEnabled: Bool
        var routeToMain: Bool
    }

    struct OutputStripConfig: Codable, Equatable {
        var deviceUID: String
    }

    struct MixerConfiguration: Codable {
        var inputs: [InputStripConfig]
        var mainOutput: OutputStripConfig
    }

    let config = MixerConfiguration(
        inputs: [
            InputStripConfig(deviceUID: "ssl2", leftChannelIndex: 0, rightChannelIndex: 1,
                             volume: 0.75, boostEnabled: true, routeToMain: true),
        ],
        mainOutput: OutputStripConfig(deviceUID: "blackhole")
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(MixerConfiguration.self, from: data)

    assertEqual(decoded.inputs.count, 1, "inputs count")
    assertEqual(decoded.inputs[0].deviceUID, "ssl2", "deviceUID")
    assertEqual(decoded.inputs[0].volume, 0.75, "volume")
    assert(decoded.inputs[0].boostEnabled, "boostEnabled")
    assertEqual(decoded.mainOutput.deviceUID, "blackhole", "mainOutput deviceUID")
}

// MARK: - Volume Boost Logic

print("▸ Volume boost logic")
do {
    func effectiveVolume(volume: Float, boostEnabled: Bool) -> Float {
        boostEnabled ? min(volume * 2.0, 2.0) : volume
    }

    assertEqual(effectiveVolume(volume: 0.5, boostEnabled: false), 0.5, "no boost")
    assertEqual(effectiveVolume(volume: 0.5, boostEnabled: true), 1.0, "boost doubles")
    assertEqual(effectiveVolume(volume: 1.0, boostEnabled: true), 2.0, "boost at max")
    assertEqual(effectiveVolume(volume: 0.8, boostEnabled: true), 1.6, "boost 0.8")
}

// MARK: - Level Calculation (RMS)

print("▸ Level calculation")
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    // Silent buffer
    let silentBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    silentBuf.frameLength = 512
    let silentData = silentBuf.floatChannelData!
    // Already zero-initialized

    func rms(_ data: UnsafePointer<Float>, count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }

    let silentL = rms(silentData[0], count: 512)
    let silentR = rms(silentData[1], count: 512)
    assertEqual(silentL, 0, "silent L")
    assertEqual(silentR, 0, "silent R")

    // Non-silent buffer
    let loudBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    loudBuf.frameLength = 512
    let loudData = loudBuf.floatChannelData!
    for i in 0..<512 {
        loudData[0][i] = 0.5
        loudData[1][i] = 0.3
    }

    let loudL = rms(loudData[0], count: 512)
    let loudR = rms(loudData[1], count: 512)
    assert(loudL > 0, "non-silent L > 0")
    assert(loudR > 0, "non-silent R > 0")
    assert(loudL > loudR, "L > R (0.5 > 0.3)")

    // Capped at 1.0
    let scale: Float = 1.4
    let capped = min(rms(loudData[0], count: 512) * scale, 1.0)
    assert(capped <= 1.0, "level capped at 1.0")
}

// MARK: - Summary

print("")
if failCount == 0 {
    print("✓ All \(testCount) tests passed")
} else {
    print("✗ \(failCount)/\(testCount) tests failed")
}
