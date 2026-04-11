// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioMixer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AudioMixer",
            path: "Sources/AudioMixer",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
