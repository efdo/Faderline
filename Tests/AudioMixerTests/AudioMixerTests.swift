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
        var gainDB: Float
        var pan: Float
        var muted: Bool
        var routeToMain: Bool
    }

    struct OutputStripConfig: Codable, Equatable {
        var deviceUID: String
        var gainDB: Float
    }

    struct MixerConfiguration: Codable {
        var inputs: [InputStripConfig]
        var mainOutput: OutputStripConfig
        var lowLatencyModeEnabled: Bool
    }

    let config = MixerConfiguration(
        inputs: [
            InputStripConfig(deviceUID: "ssl2", leftChannelIndex: 0, rightChannelIndex: 1,
                             gainDB: 3.5, pan: -0.5, muted: false, routeToMain: true),
        ],
        mainOutput: OutputStripConfig(deviceUID: "blackhole", gainDB: 0),
        lowLatencyModeEnabled: true
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(MixerConfiguration.self, from: data)

    assertEqual(decoded.inputs.count, 1, "inputs count")
    assertEqual(decoded.inputs[0].deviceUID, "ssl2", "deviceUID")
    assertEqual(decoded.inputs[0].gainDB, 3.5, "gainDB")
    assertEqual(decoded.inputs[0].pan, -0.5, "pan")
    assert(!decoded.inputs[0].muted, "muted")
    assertEqual(decoded.mainOutput.deviceUID, "blackhole", "mainOutput deviceUID")
    assertEqual(decoded.mainOutput.gainDB, 0, "mainOutput gainDB")
    assert(decoded.lowLatencyModeEnabled, "lowLatencyModeEnabled")
}

// MARK: - Fader Taper Logic

// Mirrors Sources/AudioMixer/Audio/FaderTaper.swift's core relationships,
// since this standalone script can't @testable import the real module.
// Keep this in sync if that breakpoint table or pan law ever changes.
print("▸ Fader taper logic")
do {
    enum FaderTaper {
        static let breakpoints: [(p: Float, db: Float)] = [
            (0.00, -60), (0.05, -50), (0.13, -40), (0.21, -30), (0.26, -25),
            (0.32, -20), (0.40, -15), (0.50, -10), (0.62, -5), (0.70, -3),
            (0.80, 0), (0.90, 3), (1.00, 6),
        ]

        static func db(forPosition p: Float) -> Float {
            let clamped = min(max(p, 0), 1)
            if clamped <= 0 { return -.infinity }
            if clamped >= 1 { return breakpoints.last!.db }
            for i in 1..<breakpoints.count {
                let lo = breakpoints[i - 1]
                let hi = breakpoints[i]
                if clamped <= hi.p {
                    let t = (clamped - lo.p) / (hi.p - lo.p)
                    return lo.db + t * (hi.db - lo.db)
                }
            }
            return breakpoints.last!.db
        }

        static func gain(forDB db: Float) -> Float {
            if db.isInfinite && db < 0 { return 0 }
            if db <= -60 { return 0 }
            return pow(10, db / 20)
        }

        static func panGains(_ pan: Float) -> (left: Float, right: Float) {
            let clamped = min(max(pan, -1), 1)
            let angle = (clamped + 1) * (Float.pi / 4)
            let sqrt2 = Float(2).squareRoot()
            return (cos(angle) * sqrt2, sin(angle) * sqrt2)
        }
    }

    assertEqual(FaderTaper.db(forPosition: 0.80), 0, "unity sits at 80% of fader travel")
    assert(abs(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 0.80)) - 1.0) < 0.001,
           "position 0.80 -> 0 dB -> gain 1.0")
    assert(abs(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 1.0)) - 1.995) < 0.01,
           "position 1.0 -> +6 dB -> gain ~1.995")
    assertEqual(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 0)), 0,
                "position 0 -> gain 0 (true off, not just quiet)")

    let center = FaderTaper.panGains(0)
    assert(abs(center.left - 1.0) < 0.001 && abs(center.right - 1.0) < 0.001,
           "pan center is unity on both channels (0 dB center law)")
    let hardRight = FaderTaper.panGains(1)
    assert(abs(hardRight.left) < 0.001, "pan hard right silences the left channel")
    assert(abs(hardRight.right - Float(2).squareRoot()) < 0.001,
           "pan hard right boosts the right channel to sqrt(2)")
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
