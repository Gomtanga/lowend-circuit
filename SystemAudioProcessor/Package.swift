// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SystemAudioProcessor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SystemAudioProcessor", targets: ["SystemAudioProcessor"]),
        .library(name: "LowEndSupport", targets: ["LowEndSupport"])
    ],
    targets: [
        .target(name: "LowEndSupport"),
        .target(
            name: "AudioRingBufferC",
            path: "Sources/AudioRingBufferC"
        ),
        .target(
            name: "LowEndDSPCoreC",
            dependencies: ["AudioRingBufferC"],
            path: "Sources/LowEndDSPCoreC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SystemAudioProcessor",
            dependencies: ["AudioRingBufferC", "LowEndDSPCoreC", "LowEndSupport"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SceneKit")
            ]
        ),
        .executableTarget(
            name: "LowEndSupportChecks",
            dependencies: ["AudioRingBufferC", "LowEndDSPCoreC", "LowEndSupport"],
            path: "Tests/LowEndSupportChecks"
        )
    ]
)
