import AVFoundation

/// Provides real-time audio level data from an AVAudioNode tap.
final class LevelMeter: @unchecked Sendable {
    private(set) var leftLevel: Float = 0
    private(set) var rightLevel: Float = 0

    /// Install a tap on the given node to continuously update levels.
    func attachTap(to node: AVAudioNode, bus: Int = 0) {
        let format = node.outputFormat(forBus: bus)
        guard format.channelCount > 0 else { return }

        node.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = MixerEngine.calculateLevels(buffer: buffer)
            self.leftLevel = levels.left
            self.rightLevel = levels.right
        }
    }

    func detachTap(from node: AVAudioNode, bus: Int = 0) {
        node.removeTap(onBus: bus)
        leftLevel = 0
        rightLevel = 0
    }
}
