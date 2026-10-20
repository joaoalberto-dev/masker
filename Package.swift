// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Masker",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MaskerCore",
            path: "Sources/Masker",
            exclude: ["App.swift"],
            sources: ["Camera.swift"]
        ),
        .testTarget(
            name: "MaskerCoreTests",
            dependencies: ["MaskerCore"],
            path: "Tests/MaskerCoreTests"
        )
    ]
)
