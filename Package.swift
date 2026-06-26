// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MusicIsland",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MusicIsland", targets: ["MusicIsland"])
    ],
    targets: [
        .executableTarget(
            name: "MusicIsland",
            path: "Sources/MusicIsland"
        ),
        .testTarget(
            name: "MusicIslandTests",
            dependencies: ["MusicIsland"],
            path: "Tests/MusicIslandTests"
        )
    ]
)
