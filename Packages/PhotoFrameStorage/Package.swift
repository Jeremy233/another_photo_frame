// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoFrameStorage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoFrameStorage", targets: ["PhotoFrameStorage"]),
    ],
    dependencies: [
        .package(path: "../PhotoFrameCore"),
    ],
    targets: [
        .target(
            name: "PhotoFrameStorage",
            dependencies: [.product(name: "PhotoFrameCore", package: "PhotoFrameCore")],
            resources: [.copy("Resources/platforms.json")]),
        .testTarget(name: "PhotoFrameStorageTests", dependencies: ["PhotoFrameStorage"]),
    ]
)
