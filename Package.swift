// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lacquer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lacquer", targets: ["Lacquer"])
    ],
    targets: [
        .executableTarget(
            name: "Lacquer",
            path: "Sources/Lacquer"
        ),
        .testTarget(
            name: "LacquerTests",
            dependencies: ["Lacquer"],
            path: "Tests/LacquerTests"
        )
    ]
)
