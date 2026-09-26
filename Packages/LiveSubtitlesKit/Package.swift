// swift-tools-version: 6.0
import PackageDescription

// The study-side core: storage, models, and (later) the analysis pipeline.
//
// Deliberately free of AppKit and SwiftUI so it can be exercised without launching the
// app, and so the overlay's code path can never accidentally depend on it. It is a local
// package rather than a separate repository on purpose: extraction later is a directory
// move plus one line of Package.swift, with no API change.
let package = Package(
    name: "LiveSubtitlesKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveSubtitlesKit", targets: ["LiveSubtitlesKit"]),
    ],
    targets: [
        .target(
            name: "LiveSubtitlesKit",
            path: "Sources/LiveSubtitlesKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LiveSubtitlesKitTests",
            dependencies: ["LiveSubtitlesKit"],
            path: "Tests/LiveSubtitlesKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
