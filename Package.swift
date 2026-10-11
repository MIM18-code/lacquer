// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BluRayCompressor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BluRayCompressor", targets: ["BluRayCompressor"])
    ],
    targets: [
        .executableTarget(
            name: "BluRayCompressor",
            path: "Sources/BluRayCompressor"
        ),
        .testTarget(
            name: "BluRayCompressorTests",
            dependencies: ["BluRayCompressor"],
            path: "Tests/BluRayCompressorTests"
        )
    ]
)
