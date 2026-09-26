// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubtitles",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "LiveSubtitles",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LiveSubtitles",
            // Swift 5 language mode: the audio pipeline passes non-Sendable
            // AVAudioPCMBuffer through an ordered stream on purpose.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
