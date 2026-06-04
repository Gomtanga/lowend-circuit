// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SystemAudioProcessor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SystemAudioProcessor", targets: ["SystemAudioProcessor"])
    ],
    targets: [
        .target(
            name: "AudioRingBufferC",
            path: "Sources/AudioRingBufferC"
        ),
        .executableTarget(
            name: "SystemAudioProcessor",
            dependencies: ["AudioRingBufferC"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SceneKit")
            ]
        )
    ]
)
