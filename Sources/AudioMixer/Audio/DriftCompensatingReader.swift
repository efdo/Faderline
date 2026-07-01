import Foundation

/// Pulls planar audio from a `ChannelRingBuffer` across a clock-domain
/// boundary, resampling with linear interpolation at a servo-tuned ratio.
///
/// Two jobs in one:
/// 1. **Nominal rate conversion** — seed ratio = inputRate / outputRate
///    (e.g. 44100/48000), so a 44.1k device feeds a 48k output correctly.
/// 2. **Drift compensation** — the producer and consumer clocks drift even at
///    equal nominal rates. A slow proportional servo nudges the ratio by a few
///    ppm per callback to hold the ring-buffer fill at a target level,
///    absorbing drift without audible pitch change and without ever letting
///    the buffer slowly drain (clicks) or fill (latency growth / drops).
///
/// Single consumer per ring buffer. `pull` is real-time safe after init:
/// no allocation, no locks.
final class DriftCompensatingReader {
    private let ring: ChannelRingBuffer
    private let baseRatio: Double
    private let targetFill: Int

    /// Fractional read position within the current input frame [0, 1).
    private var phase: Double = 0
    /// Current drift correction, dimensionless (±ppm range).
    private var correction: Double = 0

    /// Max correction magnitude: ±2000 ppm (0.2%) — inaudible pitch-wise,
    /// large enough to out-run any sane hardware clock drift.
    private let maxCorrection = 0.002
    /// Proportional gain: fraction of the (normalized) fill error applied
    /// per pull. Small = slow, stable convergence.
    private let gain = 0.02

    /// Scratch holding input frames for one quantum (per channel).
    private let scratch: [UnsafeMutablePointer<Float>]
    private let scratchCapacity: Int

    private(set) var starvedPullCount = 0

    var currentRatio: Double { baseRatio * (1.0 + correction) }
    var fillLevel: Int { ring.readableFrames }

    /// - Parameters:
    ///   - ring: source buffer (this reader must be its only consumer).
    ///   - inputRate: producer sample rate (device nominal rate).
    ///   - outputRate: consumer sample rate (output device rate).
    ///   - targetFill: fill level (frames) the servo holds; ~2 output quanta.
    ///   - maxQuantum: largest `frameCount` a pull may request.
    init(ring: ChannelRingBuffer,
         inputRate: Double,
         outputRate: Double,
         targetFill: Int = 2048,
         maxQuantum: Int = 4096) {
        precondition(inputRate > 0 && outputRate > 0)
        self.ring = ring
        self.baseRatio = inputRate / outputRate
        self.targetFill = min(targetFill, ring.capacity / 2)
        // Worst case input need: quantum * ratio * (1+maxCorrection) + 2 guard frames
        let cap = Int(Double(maxQuantum) * (inputRate / outputRate) * 1.01) + 8
        self.scratchCapacity = cap
        self.scratch = (0..<ring.channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            p.initialize(repeating: 0, count: cap)
            return p
        }
    }

    deinit {
        for p in scratch { p.deallocate() }
    }

    /// Produce `frameCount` output frames for each requested channel.
    ///
    /// - Parameters:
    ///   - channelDest: table of `ring.channelCount` destination pointers
    ///     (one per ring channel), each with room for `frameCount` floats.
    ///   - frameCount: output frames to produce.
    /// Zero-fills all outputs if the ring can't supply enough input.
    func pull(into channelDest: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        precondition(frameCount * 2 >= 0)

        updateServo()
        let ratio = currentRatio

        // Input frames needed to synthesize frameCount outputs from `phase`.
        let lastPos = phase + Double(frameCount - 1) * ratio
        let needed = Int(lastPos) + 2 // +1 for interp neighbor, +1 guard
        let available = ring.readableFrames

        guard frameCount > 0 else { return }

        if available < needed || needed > scratchCapacity {
            // Underrun: emit silence, consume nothing (data continuity resumes
            // exactly where we left off once the producer catches up).
            starvedPullCount += 1
            for c in 0..<ring.channelCount {
                memset(channelDest[c], 0, frameCount * MemoryLayout<Float>.size)
            }
            return
        }

        // Copy needed input frames into scratch (peek, then consume once).
        for c in 0..<ring.channelCount {
            _ = ring.peek(channel: c, into: scratch[c], count: needed)
        }

        // Linear interpolation per channel.
        var finalPos = 0.0
        for c in 0..<ring.channelCount {
            var pos = phase
            let src = scratch[c]
            let dst = channelDest[c]
            for i in 0..<frameCount {
                let idx = Int(pos)
                let frac = Float(pos - Double(idx))
                let a = src[idx]
                let b = src[idx + 1]
                dst[i] = a + frac * (b - a)
                pos += ratio
            }
            finalPos = pos
        }

        let consumed = Int(finalPos)
        phase = finalPos - Double(consumed)
        ring.advanceRead(by: consumed)
    }

    /// Proportional servo: nudge ratio toward holding `targetFill`.
    /// fill > target → consume faster (raise ratio); fill < target → slower.
    private func updateServo() {
        let error = Double(ring.readableFrames - targetFill) / Double(max(targetFill, 1))
        let desired = max(-1.0, min(1.0, error)) * maxCorrection
        correction += gain * (desired - correction)
    }

    func reset() {
        phase = 0
        correction = 0
        starvedPullCount = 0
    }
}
