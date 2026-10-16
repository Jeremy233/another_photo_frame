// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoFrameApplication",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoFrameApplication", targets: ["PhotoFrameApplication"]),
    ],
    dependencies: [
        .package(path: "../PhotoFrameCore"),
        .package(path: "../PhotoFrameStorage"),
        .package(path: "../PhotoFrameRendering"),
    ],
    targets: [
        .target(
            name: "PhotoFrameApplication",
            dependencies: [
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
            ]),
        .testTarget(
            name: "PhotoFrameApplicationTests",
            dependencies: [
                "PhotoFrameApplication",
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
            ]),
    ]
)
