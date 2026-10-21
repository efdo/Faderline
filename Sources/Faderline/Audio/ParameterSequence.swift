import Synchronization

/// Lock-free sequence lock for batched parameter updates (one writer, the UI
/// thread; one reader, the render thread). The counter is odd while a batch is
/// being written. A reader that starts on an even value and still sees the same
/// value after loading every parameter (with acquiring loads) read one coherent
/// batch; otherwise it keeps its previous values for that buffer. RT-safe: no
/// locks, allocation, or waiting on the reader side.
final class ParameterSequence: @unchecked Sendable {
    private let counter = Atomic<Int>(0)

    func beginWrite() {
        counter.store(counter.load(ordering: .relaxed) &+ 1, ordering: .sequentiallyConsistent)
    }

    func endWrite() {
        counter.store(counter.load(ordering: .relaxed) &+ 1, ordering: .releasing)
    }

    /// Returns a token, or nil while a batch is being written.
    func beginRead() -> Int? {
        let value = counter.load(ordering: .acquiring)
        return value & 1 == 0 ? value : nil
    }

    func validateRead(_ token: Int) -> Bool {
        counter.load(ordering: .acquiring) == token
    }
}
