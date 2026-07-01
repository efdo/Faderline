// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioMixer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AudioMixer",
            path: "Sources/AudioMixer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "AudioMixerEngineTests",
            dependencies: ["AudioMixer"],
            path: "Tests/AudioMixerEngineTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
