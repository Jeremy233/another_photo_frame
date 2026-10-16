// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoFrameRendering",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoFrameRendering", targets: ["PhotoFrameRendering"]),
    ],
    dependencies: [
        .package(path: "../PhotoFrameCore"),
        .package(path: "../PhotoFrameStorage"),
    ],
    targets: [
        .target(
            name: "PhotoFrameRendering",
            dependencies: [
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
            ]),
        .testTarget(
            name: "PhotoFrameRenderingTests",
            dependencies: [
                "PhotoFrameRendering",
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
            ],
            exclude: ["Golden"]),
    ]
)
