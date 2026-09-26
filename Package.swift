// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubtitles",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        // The study-side core lives in its own package so the overlay's code path cannot
        // reach it. Local for now; see docs/design/main-window.md §12.
        .package(path: "Packages/LiveSubtitlesKit"),
    ],
    targets: [
        .executableTarget(
            name: "LiveSubtitles",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "LiveSubtitlesKit", package: "LiveSubtitlesKit"),
            ],
            path: "Sources/LiveSubtitles",
            // Swift 5 language mode: the audio pipeline passes non-Sendable
            // AVAudioPCMBuffer through an ordered stream on purpose.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
