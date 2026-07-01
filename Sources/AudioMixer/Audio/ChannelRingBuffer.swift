import Foundation
import Synchronization

/// A lock-free SPSC ring buffer holding N planar (deinterleaved) Float32 channels.
///
/// Real-time safe on both sides: no locks, no allocation after init.
/// - Producer (AUHAL input callback) calls `write` only.
/// - Consumer (AUHAL output render callback) calls `read`/`readableFrames` only.
///
/// Thread safety comes from single-writer/single-reader discipline plus
/// acquire/release atomics on the head indices: the writer publishes data
/// before advancing `writeHead` (release), the reader observes `writeHead`
/// (acquire) before touching data, and vice versa for `readHead`.
final class ChannelRingBuffer: @unchecked Sendable {
    let channelCount: Int
    let capacity: Int
    private let mask: Int
    private let storage: [UnsafeMutablePointer<Float>]

    private let writeHead = Atomic<Int>(0)
    private let readHead = Atomic<Int>(0)

    private let underruns = Atomic<Int>(0)
    private let overruns = Atomic<Int>(0)

    /// - Parameters:
    ///   - channelCount: number of planar channels stored.
    ///   - capacity: frames per channel; rounded up to a power of two.
    init(channelCount: Int, capacity: Int = 16384) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        let cap = 1 << Int(ceil(log2(Double(max(capacity, 64)))))
        self.capacity = cap
        self.mask = cap - 1
        self.storage = (0..<channelCount).map { _ in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            ptr.initialize(repeating: 0, count: cap)
            return ptr
        }
    }

    deinit {
        for ptr in storage { ptr.deallocate() }
    }

    // MARK: - Introspection (any thread)

    var readableFrames: Int {
        writeHead.load(ordering: .acquiring) - readHead.load(ordering: .acquiring)
    }

    var writableFrames: Int {
        capacity - readableFrames
    }

    var underrunCount: Int { underruns.load(ordering: .relaxed) }
    var overrunCount: Int { overruns.load(ordering: .relaxed) }

    // MARK: - Producer side

    /// Write `count` frames from planar source pointers (one per channel).
    /// If the buffer is full, the oldest unread frames are NOT overwritten;
    /// instead excess input frames are dropped and `overrunCount` increments.
    /// Dropping input (vs. corrupting the read region) keeps the reader glitch-local.
    func write(channels: [UnsafePointer<Float>], count: Int) {
        precondition(channels.count == channelCount)
        channels.withUnsafeBufferPointer { chans in
            write(channelPointers: chans.baseAddress!, count: count)
        }
    }

    /// Pointer-based variant safe to call from a real-time thread
    /// (no Array allocation if the caller keeps a persistent pointer table).
    func write(channelPointers: UnsafePointer<UnsafePointer<Float>>, count: Int) {
        let wh = writeHead.load(ordering: .relaxed)
        let rh = readHead.load(ordering: .acquiring)
        let free = capacity - (wh - rh)
        let toWrite = min(count, free)
        if toWrite < count {
            overruns.wrappingAdd(1, ordering: .relaxed)
        }
        guard toWrite > 0 else { return }

        let startIdx = wh & mask
        let firstPart = min(toWrite, capacity - startIdx)
        let secondPart = toWrite - firstPart

        for c in 0..<channelCount {
            let src = channelPointers[c]
            memcpy(storage[c] + startIdx, src, firstPart * MemoryLayout<Float>.size)
            if secondPart > 0 {
                memcpy(storage[c], src + firstPart, secondPart * MemoryLayout<Float>.size)
            }
        }

        writeHead.store(wh + toWrite, ordering: .releasing)
    }

    // MARK: - Consumer side

    /// Read up to `count` frames of a single channel into `dest` WITHOUT
    /// consuming them. Returns frames actually copied (rest untouched).
    /// Used by per-strip readers that share one device buffer; consumption
    /// is performed separately via `advanceRead`.
    func peek(channel: Int, into dest: UnsafeMutablePointer<Float>, count: Int, offset: Int = 0) -> Int {
        let rh = readHead.load(ordering: .relaxed) + offset
        let wh = writeHead.load(ordering: .acquiring)
        let available = wh - rh
        let toRead = min(count, max(0, available))
        guard toRead > 0 else { return 0 }

        let startIdx = rh & mask
        let firstPart = min(toRead, capacity - startIdx)
        let secondPart = toRead - firstPart
        let src = storage[channel]
        memcpy(dest, src + startIdx, firstPart * MemoryLayout<Float>.size)
        if secondPart > 0 {
            memcpy(dest + firstPart, src, secondPart * MemoryLayout<Float>.size)
        }
        return toRead
    }

    /// Consume `count` frames (all channels). Call after all channel peeks
    /// for the current quantum are done.
    func advanceRead(by count: Int) {
        let rh = readHead.load(ordering: .relaxed)
        let wh = writeHead.load(ordering: .acquiring)
        let available = wh - rh
        let toAdvance = min(count, available)
        if toAdvance < count {
            underruns.wrappingAdd(1, ordering: .relaxed)
        }
        readHead.store(rh + toAdvance, ordering: .releasing)
    }

    /// Read-and-consume a single channel, zero-filling on underrun.
    /// Convenience for single-consumer-per-buffer uses and tests.
    func read(channel: Int, into dest: UnsafeMutablePointer<Float>, count: Int) {
        let copied = peek(channel: channel, into: dest, count: count)
        if copied < count {
            memset(dest + copied, 0, (count - copied) * MemoryLayout<Float>.size)
        }
        if channel == channelCount - 1 {
            advanceRead(by: count)
        }
    }

    // MARK: - Control (non-real-time)

    /// Pre-fill with `frames` of silence so the reader has a jitter cushion.
    func prefillSilence(frames: Int) {
        let f = min(frames, capacity)
        for c in 0..<channelCount {
            memset(storage[c], 0, f * MemoryLayout<Float>.size)
        }
        readHead.store(0, ordering: .relaxed)
        writeHead.store(f, ordering: .releasing)
    }

    func reset() {
        readHead.store(0, ordering: .relaxed)
        writeHead.store(0, ordering: .releasing)
        underruns.store(0, ordering: .relaxed)
        overruns.store(0, ordering: .relaxed)
    }
}
