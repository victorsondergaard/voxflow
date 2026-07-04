// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoxFlow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VoxFlow",
            path: "Sources/VoxFlow"
        )
    ]
)
