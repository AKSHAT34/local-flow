// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
        .executable(name: "LocalFlowApp", targets: ["LocalFlowApp"]),
        .executable(name: "LocalFlowChecks", targets: ["LocalFlowChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0")
    ],
    targets: [
        .target(
            name: "LocalFlowCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/LocalFlowCore"
        ),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: ["LocalFlowCore"],
            path: "Sources/LocalFlowApp"
        ),
        .executableTarget(
            name: "LocalFlowChecks",
            dependencies: ["LocalFlowCore"],
            path: "Sources/LocalFlowChecks"
        ),
        .testTarget(
            name: "LocalFlowTests",
            dependencies: ["LocalFlowCore"],
            path: "Tests/LocalFlowTests"
        )
    ]
)
