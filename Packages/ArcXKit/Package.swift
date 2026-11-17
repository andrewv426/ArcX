// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "ArcXKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArcXCore", targets: ["ArcXCore"]),
    ],
    targets: [
        // Browser state and logic. Foundation only: no AppKit, no WebKit.
        .target(
            name: "ArcXCore",
            swiftSettings: strict
        ),
        .testTarget(
            name: "ArcXCoreTests",
            dependencies: ["ArcXCore"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
