import XCTest
import CoreAudio
@testable import AudioMixer

final class ChannelRingBufferTests: XCTestCase {

    private func makeInput(_ values: [Float]) -> [Float] { values }

    func testWriteReadRoundTrip() {
        let ring = ChannelRingBuffer(channelCount: 2, capacity: 256)
        let left: [Float] = (0..<100).map { Float($0) }
        let right: [Float] = (0..<100).map { Float($0) * -1 }

        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.write(channels: [l.baseAddress!, r.baseAddress!], count: 100)
            }
        }
        XCTAssertEqual(ring.readableFrames, 100)

        var outL = [Float](repeating: 99, count: 100)
        var outR = [Float](repeating: 99, count: 100)
        outL.withUnsafeMutableBufferPointer { l in
            _ = ring.peek(channel: 0, into: l.baseAddress!, count: 100)
        }
        outR.withUnsafeMutableBufferPointer { r in
            _ = ring.peek(channel: 1, into: r.baseAddress!, count: 100)
        }
        ring.advanceRead(by: 100)

        XCTAssertEqual(outL, left)
        XCTAssertEqual(outR, right)
        XCTAssertEqual(ring.readableFrames, 0)
    }

    func testWrapAround() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 128) // rounds to 128
        var counter: Float = 0
        var readBack: [Float] = []

        // Write/read in mismatched chunk sizes to force wraps.
        for _ in 0..<50 {
            let chunk: [Float] = (0..<48).map { _ in counter += 1; return counter }
            chunk.withUnsafeBufferPointer { p in
                ring.write(channels: [p.baseAddress!], count: 48)
            }
            var out = [Float](repeating: 0, count: 48)
            out.withUnsafeMutableBufferPointer { p in
                _ = ring.peek(channel: 0, into: p.baseAddress!, count: 48)
            }
            ring.advanceRead(by: 48)
            readBack.append(contentsOf: out)
        }

        XCTAssertEqual(readBack, (1...Int(counter)).map(Float.init))
    }

    func testUnderrunZeroFillsAndCounts() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 64)
        let data: [Float] = [1, 2, 3]
        data.withUnsafeBufferPointer { p in
            ring.write(channels: [p.baseAddress!], count: 3)
        }

        var out = [Float](repeating: 7, count: 8)
        out.withUnsafeMutableBufferPointer { p in
            ring.read(channel: 0, into: p.baseAddress!, count: 8)
        }
        XCTAssertEqual(Array(out[0..<3]), [1, 2, 3])
        XCTAssertEqual(Array(out[3..<8]), [0, 0, 0, 0, 0])
        XCTAssertEqual(ring.underrunCount, 1)
    }

    func testOverrunDropsNewDataNotOldData() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 64)
        let first: [Float] = (0..<64).map(Float.init)
        first.withUnsafeBufferPointer { p in
            ring.write(channels: [p.baseAddress!], count: 64)
        }
        // Buffer full: this write must be dropped.
        let second: [Float] = [999]
        second.withUnsafeBufferPointer { p in
            ring.write(channels: [p.baseAddress!], count: 1)
        }
        XCTAssertEqual(ring.overrunCount, 1)
        XCTAssertEqual(ring.readableFrames, 64)

        var out = [Float](repeating: 0, count: 64)
        out.withUnsafeMutableBufferPointer { p in
            _ = ring.peek(channel: 0, into: p.baseAddress!, count: 64)
        }
        XCTAssertEqual(out, first)
    }

    func testPrefillSilence() {
        let ring = ChannelRingBuffer(channelCount: 2, capacity: 1024)
        ring.prefillSilence(frames: 512)
        XCTAssertEqual(ring.readableFrames, 512)

        var out = [Float](repeating: 1, count: 512)
        out.withUnsafeMutableBufferPointer { p in
            _ = ring.peek(channel: 0, into: p.baseAddress!, count: 512)
        }
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    /// SPSC smoke test: concurrent writer + reader, verify the consumed
    /// stream is a prefix-ordered sequence with no corruption.
    func testConcurrentProducerConsumer() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 4096)
        let total = 200_000
        let done = expectation(description: "producer done")

        Thread.detachNewThread {
            var value: Float = 0
            var chunk = [Float](repeating: 0, count: 128)
            var written = 0
            while written < total {
                for i in 0..<128 { value += 1; chunk[i] = value }
                var offset = 0
                while offset < 128 {
                    let free = ring.writableFrames
                    if free > 0 {
                        let n = min(free, 128 - offset)
                        chunk.withUnsafeBufferPointer { p in
                            ring.write(channels: [p.baseAddress! + offset], count: n)
                        }
                        offset += n
                    } else {
                        usleep(50)
                    }
                }
                written += 128
            }
            done.fulfill()
        }

        var expected: Float = 1
        var consumed = 0
        var out = [Float](repeating: 0, count: 256)
        while consumed < total {
            let avail = ring.readableFrames
            if avail > 0 {
                let n = min(avail, 256)
                out.withUnsafeMutableBufferPointer { p in
                    _ = ring.peek(channel: 0, into: p.baseAddress!, count: n)
                }
                ring.advanceRead(by: n)
                for i in 0..<n {
                    XCTAssertEqual(out[i], expected, "corruption at frame \(consumed + i)")
                    if out[i] != expected { return }
                    expected += 1
                }
                consumed += n
            } else {
                usleep(50)
            }
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(ring.overrunCount, 0)
        XCTAssertEqual(ring.underrunCount, 0)
    }
}

final class DriftCompensatingReaderTests: XCTestCase {

    private func writeRamp(_ ring: ChannelRingBuffer, from: Float, count: Int) {
        let data = (0..<count).map { from + Float($0) }
        data.withUnsafeBufferPointer { p in
            ring.write(channels: [p.baseAddress!], count: count)
        }
    }

    private func pull(_ reader: DriftCompensatingReader, channels: Int, frames: Int) -> [[Float]] {
        var outs = (0..<channels).map { _ in [Float](repeating: .nan, count: frames) }
        var ptrs: [UnsafeMutablePointer<Float>] = []
        for c in 0..<channels {
            outs[c].withUnsafeMutableBufferPointer { p in
                ptrs.append(p.baseAddress!)
            }
        }
        // NOTE: withUnsafeMutableBufferPointer pointers escaping above is
        // safe here because the arrays are not resized before use.
        ptrs.withUnsafeBufferPointer { table in
            reader.pull(into: table.baseAddress!, frameCount: frames)
        }
        return outs
    }

    func testUnityRatioPassthrough() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 8192)
        let reader = DriftCompensatingReader(ring: ring, inputRate: 48000, outputRate: 48000,
                                             targetFill: 1024, maxQuantum: 512)
        // Hold fill at target so the servo stays ~neutral.
        writeRamp(ring, from: 0, count: 1024)

        let out = pull(reader, channels: 1, frames: 256)[0]
        // With phase starting at 0 and ratio ≈ 1, output ≈ input ramp.
        for i in 0..<256 {
            XCTAssertEqual(out[i], Float(i), accuracy: 0.5, "frame \(i)")
        }
    }

    func testRateConversionProducesContinuousRamp() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 16384)
        // 44.1k source → 48k output: ratio < 1, consumes slower.
        let reader = DriftCompensatingReader(ring: ring, inputRate: 44100, outputRate: 48000,
                                             targetFill: 2048, maxQuantum: 1024)
        writeRamp(ring, from: 0, count: 8192)

        var previous: Float = -1
        for _ in 0..<8 {
            let out = pull(reader, channels: 1, frames: 512)[0]
            for v in out {
                XCTAssertGreaterThan(v, previous, "ramp must be strictly increasing (no discontinuity)")
                // Linear interp of a ramp: successive deltas ≈ ratio (0.919).
                if previous >= 0 {
                    XCTAssertEqual(v - previous, 44100.0/48000.0, accuracy: 0.05)
                }
                previous = v
            }
        }
    }

    func testStarvedPullEmitsSilenceAndRecovers() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 4096)
        let reader = DriftCompensatingReader(ring: ring, inputRate: 48000, outputRate: 48000,
                                             targetFill: 512, maxQuantum: 256)
        // Nothing written: pull must give silence.
        let silent = pull(reader, channels: 1, frames: 256)[0]
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
        XCTAssertEqual(reader.starvedPullCount, 1)

        // Data arrives: next pull resumes from the stream start (nothing lost).
        writeRamp(ring, from: 0, count: 1024)
        let out = pull(reader, channels: 1, frames: 256)[0]
        XCTAssertEqual(out[0], 0, accuracy: 0.5)
        XCTAssertEqual(out[255], 255, accuracy: 1.5)
    }

    func testServoConvergesTowardTargetFill() {
        let ring = ChannelRingBuffer(channelCount: 1, capacity: 16384)
        let reader = DriftCompensatingReader(ring: ring, inputRate: 48000, outputRate: 48000,
                                             targetFill: 2048, maxQuantum: 512)

        // Simulate a producer running slightly FAST (writes 514 frames per
        // 512-frame pull ≈ +0.4% drift, beyond servo range but it should
        // still push ratio to its max correction, consuming as fast as it can).
        writeRamp(ring, from: 0, count: 2048)
        var next: Float = 2048
        for _ in 0..<400 {
            writeRamp(ring, from: next, count: 514)
            next += 514
            _ = pull(reader, channels: 1, frames: 512)
        }
        XCTAssertGreaterThan(reader.currentRatio, 1.0, "servo must speed up consumption when fill grows")

        // Now producer runs SLOW (510/512): ratio must fall below 1 eventually.
        for _ in 0..<800 {
            writeRamp(ring, from: next, count: 510)
            next += 510
            _ = pull(reader, channels: 1, frames: 512)
        }
        XCTAssertLessThan(reader.currentRatio, 1.0, "servo must slow consumption when fill shrinks")
    }
}

final class HALMixerEngineConfigTests: XCTestCase {
    func testEngineStartWithUnknownOutputIsNoop() throws {
        let engine = HALMixerEngine()
        try engine.start(inputs: [], output: .init())
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.inputLevels.isEmpty)
    }

    func testStopIsIdempotent() {
        let engine = HALMixerEngine()
        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    func testParameterSettersSafeWhileStopped() {
        let engine = HALMixerEngine()
        engine.setVolume(0.5, forInput: 0)
        engine.setRouteToMain(false, forInput: 1)
        XCTAssertFalse(engine.isRunning)
    }

    // MARK: - Output routing resolution (pure, no real Core Audio devices touched)

    func testRoutingWithNoDevicesConfigured() {
        let (primary, monitor) = HALMixerEngine.resolveOutputRouting(.init())
        XCTAssertEqual(primary, AudioDeviceID(kAudioObjectUnknown))
        XCTAssertNil(monitor)
    }

    func testRoutingPrefersVirtualDeviceAsPrimaryWhenBothPresent() {
        let (primary, monitor) = HALMixerEngine.resolveOutputRouting(
            .init(virtualDeviceID: 42, monitorDeviceID: 7)
        )
        XCTAssertEqual(primary, 42, "the virtual microphone must always be the mix clock when present")
        XCTAssertEqual(monitor, 7, "the selected hardware device becomes a secondary monitor")
    }

    func testRoutingFallsBackToMonitorDeviceAsPrimaryWhenNoVirtualDevice() {
        let (primary, monitor) = HALMixerEngine.resolveOutputRouting(
            .init(monitorDeviceID: 7)
        )
        XCTAssertEqual(primary, 7, "with no virtual driver installed, the selected hardware device must still play the mix directly")
        XCTAssertNil(monitor, "there is nothing to fan out to when the monitor device IS the primary output")
    }

    func testRoutingWithOnlyVirtualDeviceHasNoMonitor() {
        let (primary, monitor) = HALMixerEngine.resolveOutputRouting(
            .init(virtualDeviceID: 42)
        )
        XCTAssertEqual(primary, 42)
        XCTAssertNil(monitor, "monitoring is optional and must stay disabled unless a hardware device is selected")
    }

    // MARK: - Engine-level rollback with unreachable devices
    //
    // These use bogus AudioDeviceIDs that don't correspond to any real
    // device. HALMixerEngine.start() queries the device's nominal sample
    // rate before creating any AUHAL unit, so these exercise the failure
    // and rollback path without touching real Core Audio hardware.

    func testEngineStartThrowsAndRollsBackWhenPrimaryDeviceIsUnreachable() {
        let engine = HALMixerEngine()
        XCTAssertThrowsError(
            try engine.start(inputs: [], output: .init(virtualDeviceID: 999_999))
        )
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.inputLevels.isEmpty)
        XCTAssertEqual(engine.outputLevel.left, 0)
    }

    func testEngineStartThrowsWhenHardwareFallbackDeviceIsUnreachable() {
        let engine = HALMixerEngine()
        XCTAssertThrowsError(
            try engine.start(inputs: [], output: .init(monitorDeviceID: 999_999))
        )
        XCTAssertFalse(engine.isRunning)
    }
}
