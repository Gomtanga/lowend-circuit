// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SystemAudioProcessor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SystemAudioProcessor", targets: ["SystemAudioProcessor"])
    ],
    targets: [
        .executableTarget(
            name: "SystemAudioProcessor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
