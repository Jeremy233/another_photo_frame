// swift-tools-version: 6.2
import PackageDescription

/// 命令行工具 `photoframe`（规范 §11.3）。命令实现在 `PhotoFrameCLI` 库里，可执行文件只负责进程级的事
/// （信号、标准输出、退出码），测试可以在进程内直接调用命令。
let package = Package(
    name: "photoframe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "photoframe", targets: ["photoframe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(path: "../../Packages/PhotoFrameCore"),
        .package(path: "../../Packages/PhotoFrameStorage"),
        .package(path: "../../Packages/PhotoFrameApplication"),
        .package(path: "../../Packages/PhotoFrameEngine"),
    ],
    targets: [
        .target(
            name: "PhotoFrameCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
                .product(name: "PhotoFrameEngine", package: "PhotoFrameEngine"),
            ]),
        .executableTarget(name: "photoframe", dependencies: ["PhotoFrameCLI"]),
        .testTarget(
            name: "PhotoFrameCLITests",
            dependencies: [
                "PhotoFrameCLI",
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
                .product(name: "PhotoFrameEngine", package: "PhotoFrameEngine"),
                // 让 `swift test` 先构建可执行文件，端到端测试以子进程运行它。
                "photoframe",
            ]),
    ]
)
