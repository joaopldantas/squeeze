// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Squeeze",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SqueezeCore", targets: ["SqueezeCore"]),
        .executable(name: "squeeze", targets: ["SqueezeCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "SqueezeCore"),
        .executableTarget(
            name: "SqueezeCLI",
            dependencies: [
                "SqueezeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SqueezeCoreTests",
            dependencies: ["SqueezeCore"]
        ),
        .testTarget(
            name: "SqueezeCLITests",
            dependencies: ["SqueezeCLI"]
        ),
        .testTarget(
            name: "SqueezeIntegrationTests",
            dependencies: ["SqueezeCore"]
        )
    ]
)
