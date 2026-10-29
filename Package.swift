// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Squeeze",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SqueezeCore", targets: ["SqueezeCore"])
    ],
    targets: [
        .target(name: "SqueezeCore"),
        .testTarget(
            name: "SqueezeCoreTests",
            dependencies: ["SqueezeCore"]
        ),
        .testTarget(
            name: "SqueezeIntegrationTests",
            dependencies: ["SqueezeCore"]
        )
    ]
)
