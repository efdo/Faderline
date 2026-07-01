import SwiftUI

/// The engine implementation in use. Switch back to `LegacyMixerEngine`
/// (AVAudioEngine-based) here for A/B comparison during hardware testing.
typealias ActiveMixerEngine = HALMixerEngine

/// Top-level ViewModel coordinating all strips and the audio engine.
@Observable
final class MixerViewModel {
    let deviceManager = DeviceManager()
    let mixerEngine = ActiveMixerEngine()

    var inputStrips: [InputStripViewModel]
    var mainOutput: OutputStripViewModel

    private var levelTimer: Timer?

    init() {
        inputStrips = [
            InputStripViewModel(id: 0, label: "Input 1"),
            InputStripViewModel(id: 1, label: "Input 2"),
        ]
        mainOutput = OutputStripViewModel(id: 0, label: "Main Output")

        loadConfiguration()
        startLevelPolling()
        rebuildEngine()
    }

    deinit {
        levelTimer?.invalidate()
    }

    // MARK: - Actions

    func selectInputDevice(_ device: AudioDevice, forStrip strip: InputStripViewModel) {
        strip.selectedDevice = device
        strip.leftChannelIndex = 0
        strip.rightChannelIndex = min(1, device.inputChannelCount - 1)
        rebuildEngine()
    }

    func selectOutputDevice(_ device: AudioDevice) {
        mainOutput.selectedDevice = device
        rebuildEngine()
    }

    func updateVolume(_ volume: Float, forStrip strip: InputStripViewModel) {
        strip.volume = volume
        mixerEngine.setVolume(strip.effectiveVolume, forInput: strip.id)
        saveConfiguration()
    }

    func toggleBoost(forStrip strip: InputStripViewModel) {
        strip.boostEnabled.toggle()
        mixerEngine.setVolume(strip.effectiveVolume, forInput: strip.id)
        saveConfiguration()
    }

    func toggleRouteToMain(forStrip strip: InputStripViewModel) {
        strip.routeToMain.toggle()
        mixerEngine.setRouteToMain(strip.routeToMain, forInput: strip.id)
        saveConfiguration()
    }

    func setLeftChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.leftChannelIndex = index
        rebuildEngine()
    }

    func setRightChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.rightChannelIndex = index
        rebuildEngine()
    }

    // MARK: - Engine management

    private func rebuildEngine() {
        print("[MixerVM] rebuildEngine called")
        print("[MixerVM]   output device: id=\(mainOutput.selectedDevice.id), name=\(mainOutput.selectedDevice.name), uid=\(mainOutput.selectedDevice.uid)")
        for strip in inputStrips {
            print("[MixerVM]   input[\(strip.id)]: id=\(strip.selectedDevice.id), name=\(strip.selectedDevice.name), routeToMain=\(strip.routeToMain), L=\(strip.leftChannelIndex) R=\(strip.rightChannelIndex)")
        }

        let inputs = inputStrips.map { strip in
            ActiveMixerEngine.InputConfig(
                deviceID: strip.selectedDevice.id,
                leftChannel: strip.leftChannelIndex,
                rightChannel: strip.rightChannelIndex,
                volume: strip.effectiveVolume,
                routeToMain: strip.routeToMain
            )
        }

        let output = ActiveMixerEngine.OutputConfig(
            deviceID: mainOutput.selectedDevice.id
        )

        do {
            try mixerEngine.start(inputs: inputs, output: output)
            print("[MixerVM] ✅ Engine started successfully, isRunning=\(mixerEngine.isRunning)")
        } catch {
            print("[MixerVM] ❌ MixerEngine failed to start: \(error)")
            mixerEngine.lastError = error.localizedDescription
        }

        saveConfiguration()
    }

    // MARK: - Level metering

    private func startLevelPolling() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Copy engine levels to view models
            for strip in self.inputStrips {
                if let levels = self.mixerEngine.inputLevels[strip.id] {
                    strip.levelLeft = levels.left
                    strip.levelRight = levels.right
                } else {
                    strip.levelLeft *= 0.8
                    strip.levelRight *= 0.8
                }
            }
            self.mainOutput.levelLeft = self.mixerEngine.outputLevel.left
            self.mainOutput.levelRight = self.mixerEngine.outputLevel.right
        }
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        let config = MixerConfiguration(
            inputs: inputStrips.map { strip in
                MixerConfiguration.InputStripConfig(
                    deviceUID: strip.selectedDevice.uid,
                    leftChannelIndex: strip.leftChannelIndex,
                    rightChannelIndex: strip.rightChannelIndex,
                    volume: strip.volume,
                    boostEnabled: strip.boostEnabled,
                    routeToMain: strip.routeToMain
                )
            },
            mainOutput: MixerConfiguration.OutputStripConfig(
                deviceUID: mainOutput.selectedDevice.uid
            )
        )
        config.save()
    }

    private func loadConfiguration() {
        let config = MixerConfiguration.load()

        for (i, stripConfig) in config.inputs.enumerated() where i < inputStrips.count {
            let strip = inputStrips[i]
            if let device = deviceManager.device(forUID: stripConfig.deviceUID) {
                strip.selectedDevice = device
            }
            strip.leftChannelIndex = stripConfig.leftChannelIndex
            strip.rightChannelIndex = stripConfig.rightChannelIndex
            strip.volume = stripConfig.volume
            strip.boostEnabled = stripConfig.boostEnabled
            strip.routeToMain = stripConfig.routeToMain
        }

        if let device = deviceManager.device(forUID: config.mainOutput.deviceUID) {
            mainOutput.selectedDevice = device
        }
    }
}
