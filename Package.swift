// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode is deliberate: the app is built around AppKit main-thread
// conventions and Carbon/Apple Event C APIs, none of which are Sendable-annotated.
// Strict Swift 6 concurrency checking would add noise without adding safety here.
let package = Package(
    name: "SpaceSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpaceSwitcher",
            path: "Sources/SpaceSwitcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
