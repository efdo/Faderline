// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Faderline",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Faderline",
            path: "Sources/Faderline",
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
            name: "FaderlineEngineTests",
            dependencies: ["Faderline"],
            path: "Tests/FaderlineEngineTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
