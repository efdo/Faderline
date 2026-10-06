import XCTest
import CoreAudio
import AppKit
import SwiftUI
@testable import Faderline

@MainActor
final class InitialWindowFocusTests: XCTestCase {
    func testEscapeClearsFocusAndTabRestoresIt() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let content = NSHostingView(rootView:
            TextField("Gain", text: .constant("0.0"))
                .background(InitialWindowFocus())
        )
        let container = NSView(frame: window.contentLayoutRect)
        content.frame = container.bounds
        container.addSubview(content)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        content.layoutSubtreeIfNeeded()
        await drainMainQueue()

        func findField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        let field = try XCTUnwrap(findField(in: content))
        XCTAssertTrue(window.makeFirstResponder(field))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NSApp.sendEvent(escape)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        NSApp.sendEvent(escape)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === window)

        window.recalculateKeyViewLoop()
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        XCTAssertNotNil(field.currentEditor())

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        picker.addItem(withTitle: "Device")
        container.addSubview(picker)
        XCTAssertTrue(window.makeFirstResponder(picker))
        NSApp.sendEvent(escape)
        XCTAssertTrue(window.firstResponder === window)
    }

    func testInitialFocusClearedButLaterFocusPreserved() async {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let content = NSView(frame: window.contentLayoutRect)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        let initialFocus = InitialWindowFocusView()
        content.addSubview(field)
        content.addSubview(initialFocus)
        window.contentView = content
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(window.firstResponder as? NSTextView)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === window)

        window.recalculateKeyViewLoop()
        window.selectNextKeyView(nil)
        XCTAssertNotNil(window.firstResponder as? NSTextView)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        let focusedResponder = window.firstResponder
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === focusedResponder)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

final class ConsoleLayoutTests: XCTestCase {
    func testPanKnobFitsExistingRow() {
        XCTAssertEqual(MixerTheme.Metrics.panKnobDiameter, 36)
        XCTAssertLessThan(MixerTheme.Metrics.panKnobDiameter, ConsoleRow.pan.height)
    }

    func testMinimumSizeFitsTwoInputsAndMainWithoutWideningStrips() {
        let size = MixerTheme.Metrics.consoleMinimumSize(inputCount: 2)
        XCTAssertEqual(MixerTheme.Metrics.stripWidth, 125)
        XCTAssertEqual(size.width, 529)
        XCTAssertEqual(size.height, 484)
    }

    func testMinimumWidthTracksInputCount() {
        let mainOnly = MixerTheme.Metrics.consoleMinimumSize(inputCount: 0)
        let fourInputs = MixerTheme.Metrics.consoleMinimumSize(inputCount: 4)
        XCTAssertEqual(mainOnly.width, 263)
        XCTAssertEqual(fourInputs.width, 795)
        XCTAssertEqual(mainOnly.height, fourInputs.height)
    }
}

final class PanKnobTests: XCTestCase {
    func testHoverTextDescribesCurrentPan() {
        XCTAssertEqual(PanKnobView.helpText(for: 0), "Pan: Center")
        XCTAssertEqual(PanKnobView.helpText(for: -1), "Pan: 100% Left")
        XCTAssertEqual(PanKnobView.helpText(for: 1), "Pan: 100% Right")
        XCTAssertEqual(PanKnobView.helpText(for: -0.42), "Pan: 42% Left")
        XCTAssertEqual(PanKnobView.helpText(for: 0.25), "Pan: 25% Right")
    }

    func testCenterSnapIncludesBothEdges() {
        for translation: CGFloat in [-4, -2, 0, 2, 4] {
            XCTAssertEqual(PanKnobView.pan(
                forDragTranslation: translation, startPan: 0, diameter: 100
            ), 0)
        }
    }

    func testDraggingPastCenterSnapMovesInBothDirections() {
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: -5, startPan: 0, diameter: 100
        ), 0.1, accuracy: 0.0001)
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: 5, startPan: 0, diameter: 100
        ), -0.1, accuracy: 0.0001)
    }

    func testDragCanCrossCenterWithoutLosingItsOrigin() {
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: -25, startPan: -0.5, diameter: 100
        ), 0)
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: -35, startPan: -0.5, diameter: 100
        ), 0.2, accuracy: 0.0001)
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: 35, startPan: 0.5, diameter: 100
        ), -0.2, accuracy: 0.0001)
    }

    func testDragClampsAtHardLeftAndRight() {
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: 100, startPan: 0.5, diameter: 36
        ), -1)
        XCTAssertEqual(PanKnobView.pan(
            forDragTranslation: -100, startPan: -0.5, diameter: 36
        ), 1)
    }
}

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
        XCTAssertGreaterThan(reader.skippedFrameCount, 0, "same-rate fast path must skip frames when fill grows")

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
        try engine.start(inputs: [], output: .init(deviceID: kAudioObjectUnknown))
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
}

final class FaderTaperTests: XCTestCase {

    // MARK: - Position <-> dB

    func testUnityIsAt80PercentPosition() {
        XCTAssertEqual(FaderTaper.db(forPosition: 0.80), 0, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.position(forDB: 0), 0.80, accuracy: 0.001)
    }

    func testTopOfTravelIsPlus6dB() {
        XCTAssertEqual(FaderTaper.db(forPosition: 1.0), 6, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.position(forDB: 6), 1.0, accuracy: 0.001)
    }

    func testBottomOfTravelIsNegativeInfinity() {
        XCTAssertEqual(FaderTaper.db(forPosition: 0), -.infinity)
        XCTAssertEqual(FaderTaper.position(forDB: -.infinity), 0)
        // The table floor (-60 dB) also collapses to position 0 — both "-60"
        // and "off" live at the very bottom of the fader's throw.
        XCTAssertEqual(FaderTaper.position(forDB: -60), 0)
    }

    func testPositionDbRoundTrip() {
        for p: Float in stride(from: 0.01, through: 1.0, by: 0.01) {
            let db = FaderTaper.db(forPosition: p)
            let roundTripped = FaderTaper.position(forDB: db)
            XCTAssertEqual(roundTripped, p, accuracy: 0.005, "position \(p) round-trip via \(db) dB")
        }
    }

    func testDbPositionRoundTrip() {
        // Starts at -59, not -60: exactly -60 dB intentionally collapses to
        // position 0, which maps back to -.infinity (true off), not -60 —
        // that specific edge case is covered by
        // `testBottomOfTravelIsNegativeInfinity` instead.
        for db: Float in stride(from: -59, through: 6, by: 1) {
            let p = FaderTaper.position(forDB: db)
            let roundTripped = FaderTaper.db(forPosition: p)
            XCTAssertEqual(roundTripped, db, accuracy: 0.05, "dB \(db) round-trip via position \(p)")
        }
    }

    func testPositionToDbIsMonotonicallyNonDecreasing() {
        var previous = -Float.infinity
        for p: Float in stride(from: 0, through: 1.0, by: 0.02) {
            let db = FaderTaper.db(forPosition: p)
            XCTAssertGreaterThanOrEqual(db, previous, "dB must not decrease as position increases")
            previous = db
        }
    }

    func testDbToPositionIsMonotonicallyNonDecreasing() {
        var previous: Float = 0
        for db: Float in stride(from: -60, through: 6, by: 1) {
            let p = FaderTaper.position(forDB: db)
            XCTAssertGreaterThanOrEqual(p, previous, "position must not decrease as dB increases")
            previous = p
        }
    }

    // MARK: - dB <-> linear gain

    func testUnityGain() {
        XCTAssertEqual(FaderTaper.gain(forDB: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(FaderTaper.db(forGain: 1.0), 0, accuracy: 0.0001)
    }

    func testPlus6dBGainIsApproximatelyDoubled() {
        XCTAssertEqual(FaderTaper.gain(forDB: 6), 1.995, accuracy: 0.005)
    }

    func testFaderBottomIsExactlyZeroGain() {
        XCTAssertEqual(FaderTaper.gain(forDB: -.infinity), 0)
        XCTAssertEqual(FaderTaper.gain(forDB: -60), 0)
        XCTAssertEqual(FaderTaper.gain(forDB: -100), 0)
    }

    func testGainToDbForSilenceIsNegativeInfinity() {
        XCTAssertEqual(FaderTaper.db(forGain: 0), -.infinity)
        XCTAssertEqual(FaderTaper.db(forGain: -1), -.infinity)
    }

    func testGainDbRoundTrip() {
        for g: Float in [0.001, 0.01, 0.1, 0.5, 1.0, 1.5, 1.995] {
            let db = FaderTaper.db(forGain: g)
            XCTAssertEqual(FaderTaper.gain(forDB: db), g, accuracy: 0.001)
        }
    }

    // MARK: - Full chain: fader position 0.80/1.00/0.00 -> gain

    func testFullChainPositionToGain() {
        XCTAssertEqual(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 0.80)), 1.0, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 1.0)), 1.995, accuracy: 0.005)
        XCTAssertEqual(FaderTaper.gain(forDB: FaderTaper.db(forPosition: 0)), 0)
    }

    // MARK: - Display / parse

    func testDisplayString() {
        XCTAssertEqual(FaderTaper.displayString(forDB: 0), "0.0")
        XCTAssertEqual(FaderTaper.displayString(forDB: -6), "-6.0")
        XCTAssertEqual(FaderTaper.displayString(forDB: -.infinity), "-\u{221E}")
    }

    func testParseDB() {
        XCTAssertEqual(FaderTaper.parseDB("0"), 0)
        XCTAssertEqual(FaderTaper.parseDB("-6.0"), -6.0)
        XCTAssertEqual(FaderTaper.parseDB("-inf"), -.infinity)
        XCTAssertEqual(FaderTaper.parseDB("-\u{221E}"), -.infinity)
        XCTAssertNil(FaderTaper.parseDB("banana"))
        // Out-of-range finite values are clamped, not rejected.
        XCTAssertEqual(FaderTaper.parseDB("100"), FaderTaper.maxDB)
        XCTAssertEqual(FaderTaper.parseDB("-999"), FaderTaper.minDB)
    }

    func testParseDbDisplayRoundTrip() throws {
        for db: Float in [6, 3, 0, -3, -6, -20, -60] {
            let text = FaderTaper.displayString(forDB: db)
            let parsed = try XCTUnwrap(FaderTaper.parseDB(text))
            XCTAssertEqual(parsed, db, accuracy: 0.05)
        }
    }

    // MARK: - Pan law

    func testPanCenterIsUnityBothChannels() {
        let gains = FaderTaper.panGains(0)
        XCTAssertEqual(gains.left, 1.0, accuracy: 0.001)
        XCTAssertEqual(gains.right, 1.0, accuracy: 0.001)
    }

    func testPanHardRight() {
        let gains = FaderTaper.panGains(1)
        XCTAssertEqual(gains.left, 0, accuracy: 0.001)
        XCTAssertEqual(gains.right, Float(2).squareRoot(), accuracy: 0.001)
    }

    func testPanHardLeft() {
        let gains = FaderTaper.panGains(-1)
        XCTAssertEqual(gains.left, Float(2).squareRoot(), accuracy: 0.001)
        XCTAssertEqual(gains.right, 0, accuracy: 0.001)
    }

    func testPanIsClampedBeyondRange() {
        let hardRight = FaderTaper.panGains(1)
        let beyondRight = FaderTaper.panGains(5)
        XCTAssertEqual(beyondRight.left, hardRight.left, accuracy: 0.001)
        XCTAssertEqual(beyondRight.right, hardRight.right, accuracy: 0.001)
    }

    func testPanIsConstantPower() {
        // Constant-power: L^2 + R^2 stays constant (== 2) across the sweep.
        for pan: Float in stride(from: -1, through: 1, by: 0.1) {
            let gains = FaderTaper.panGains(pan)
            let power = gains.left * gains.left + gains.right * gains.right
            XCTAssertEqual(power, 2.0, accuracy: 0.001)
        }
    }
}

final class MixerConfigurationMigrationTests: XCTestCase {
    /// Mirrors the non-conforming-float strategy `MixerConfiguration.save()`/
    /// `load()` use internally (those factories are private), so decoding
    /// `-.infinity` round-trips the same way here as it does at runtime.
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    func testLegacyVolumeAndBoostMigrateToGainDB() throws {
        // A pre-console blob: linear 0...1 volume slider + a +6 dB boost toggle.
        let legacyJSON = """
        {"inputs":[{"deviceUID":"ssl2","leftChannelIndex":0,"rightChannelIndex":1,\
        "volume":0.75,"boostEnabled":true,"routeToMain":true}],\
        "mainOutput":{"deviceUID":"blackhole"},"lowLatencyModeEnabled":false}
        """
        let config = try makeDecoder().decode(MixerConfiguration.self, from: Data(legacyJSON.utf8))
        // gain = 0.75 * 2 = 1.5 -> 20*log10(1.5) ~= 3.52 dB
        XCTAssertEqual(config.inputs[0].gainDB, 3.52, accuracy: 0.05)
        XCTAssertEqual(config.inputs[0].pan, 0, "migrated configs default to centered pan")
        XCTAssertFalse(config.inputs[0].muted, "migrated configs default to unmuted")
    }

    func testLegacySilentVolumeMigratesToNegativeInfinityNotMinus60() throws {
        let legacyJSON = """
        {"inputs":[{"deviceUID":"ssl2","leftChannelIndex":0,"rightChannelIndex":1,\
        "volume":0.0,"boostEnabled":false,"routeToMain":true}],\
        "mainOutput":{"deviceUID":"blackhole"},"lowLatencyModeEnabled":false}
        """
        let config = try makeDecoder().decode(MixerConfiguration.self, from: Data(legacyJSON.utf8))
        // A fully-down legacy slider (gain exactly 0) must migrate to true
        // silence, not get clamped up into an audible -60 dB.
        XCTAssertEqual(config.inputs[0].gainDB, -.infinity)
    }

    func testLegacyConfigWithoutOutputGainDefaultsToZero() throws {
        let legacyJSON = """
        {"inputs":[],"mainOutput":{"deviceUID":"blackhole"},"lowLatencyModeEnabled":false}
        """
        let config = try makeDecoder().decode(MixerConfiguration.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(config.mainOutput.gainDB, 0)
    }

    func testNegativeInfinityGainDBRoundTripsThroughJSON() throws {
        let config = MixerConfiguration(
            inputs: [
                MixerConfiguration.InputStripConfig(
                    deviceUID: "x", leftChannelIndex: 0, rightChannelIndex: 1,
                    gainDB: -.infinity, routeToMain: true),
            ],
            mainOutput: MixerConfiguration.OutputStripConfig(deviceUID: "y")
        )
        let data = try makeEncoder().encode(config)
        let decoded = try makeDecoder().decode(MixerConfiguration.self, from: data)
        XCTAssertEqual(decoded.inputs[0].gainDB, -.infinity)
    }

    func testNewFieldsRoundTripThroughJSON() throws {
        let config = MixerConfiguration(
            inputs: [
                MixerConfiguration.InputStripConfig(
                    deviceUID: "ssl2", leftChannelIndex: 0, rightChannelIndex: 1,
                    gainDB: -4.5, pan: 0.3, muted: true, routeToMain: false),
            ],
            mainOutput: MixerConfiguration.OutputStripConfig(deviceUID: "blackhole", gainDB: -2.0)
        )
        let data = try makeEncoder().encode(config)
        let decoded = try makeDecoder().decode(MixerConfiguration.self, from: data)
        XCTAssertEqual(decoded.inputs[0].gainDB, -4.5, accuracy: 0.001)
        XCTAssertEqual(decoded.inputs[0].pan, 0.3, accuracy: 0.001)
        XCTAssertTrue(decoded.inputs[0].muted)
        XCTAssertFalse(decoded.inputs[0].routeToMain)
        XCTAssertEqual(decoded.mainOutput.gainDB, -2.0, accuracy: 0.001)
    }
}

final class SoloRoutingTests: XCTestCase {
    // A soloed-but-unrouted strip must not count toward "any solo" — it is
    // itself inaudible either way (not routed to Main), so letting it count
    // would silence every other, properly-routed strip too, turning
    // "solo this channel" into "mute everything" instead of isolating it.

    func testHALEngineSoloIgnoresUnroutedStrips() {
        XCTAssertFalse(HALMixerEngine.anySoloed(among: [(routed: false, soloed: true)]),
                        "a soloed strip that isn't routed must not trigger solo mode")
        XCTAssertTrue(HALMixerEngine.anySoloed(among: [(routed: true, soloed: true)]))
        XCTAssertTrue(HALMixerEngine.anySoloed(among: [
            (routed: false, soloed: true), (routed: true, soloed: true),
        ]), "a routed+soloed strip still triggers solo mode even alongside an unrouted soloed one")
        XCTAssertFalse(HALMixerEngine.anySoloed(among: [
            (routed: true, soloed: false), (routed: false, soloed: false),
        ]))
        XCTAssertFalse(HALMixerEngine.anySoloed(among: []))
    }

    func testLegacyEngineSoloIgnoresUnroutedStrips() {
        XCTAssertFalse(LegacyMixerEngine.anySoloed(among: [(routed: false, soloed: true)]),
                        "a soloed strip that isn't routed must not trigger solo mode")
        XCTAssertTrue(LegacyMixerEngine.anySoloed(among: [(routed: true, soloed: true)]))
    }
}

final class PeakHoldTests: XCTestCase {
    func testNewPeakLatchesToCurrentlyDecayedValueNotFrozenHistoricalHigh() {
        var hold = PeakHold()
        let t0 = Date()
        hold.register(1.0, at: t0)

        // Well past the hold+decay window, the displayed value should have
        // decayed close to silence.
        let farFuture = t0.addingTimeInterval(10)
        XCTAssertLessThan(hold.displayValue(at: farFuture), 0.01)

        // A new, much quieter but genuine ongoing peak must still register as
        // the new visible peak (it's louder than what's currently displayed)
        // — it must NOT be silently dropped just because it's below the old
        // transient's all-time high, or the meter would read "no signal"
        // forever despite real, ongoing (just quieter) audio.
        hold.register(0.3, at: farFuture)
        XCTAssertEqual(hold.displayValue(at: farFuture), 0.3, accuracy: 0.001)
    }

    func testPeakHoldsSteadyDuringHoldWindow() {
        var hold = PeakHold()
        let t0 = Date()
        hold.register(0.8, at: t0)
        let stillWithinHold = t0.addingTimeInterval(PeakHold.holdDuration - 0.1)
        XCTAssertEqual(hold.displayValue(at: stillWithinHold), 0.8, accuracy: 0.001)
    }

    func testQuieterSampleDuringHoldDoesNotKnockDownCurrentPeak() {
        var hold = PeakHold()
        let t0 = Date()
        hold.register(1.0, at: t0)
        // Immediately after (no decay has happened yet), a quieter sample
        // must not visually knock the currently-displayed peak down.
        hold.register(0.2, at: t0)
        XCTAssertEqual(hold.displayValue(at: t0), 1.0, accuracy: 0.001)
    }
}
