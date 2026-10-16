// swift-tools-version: 6.2
import PackageDescription

/// 组装层：用 PhotoFrameRendering 实现 PhotoFrameApplication 的 `JobRenderer` / `ImageAnalyzer`，
/// 并提供默认配置好的 `PhotoFrameService`。GUI、CLI、MCP 都从这里取服务（§10.1、§10.2）。
let package = Package(
    name: "PhotoFrameEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoFrameEngine", targets: ["PhotoFrameEngine"]),
    ],
    dependencies: [
        .package(path: "../PhotoFrameCore"),
        .package(path: "../PhotoFrameStorage"),
        .package(path: "../PhotoFrameRendering"),
        .package(path: "../PhotoFrameApplication"),
    ],
    targets: [
        .target(
            name: "PhotoFrameEngine",
            dependencies: [
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
            ]),
        .testTarget(name: "PhotoFrameEngineTests", dependencies: ["PhotoFrameEngine"]),
    ]
)
