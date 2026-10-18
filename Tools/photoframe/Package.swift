// swift-tools-version: 6.2
import PackageDescription

/// 命令行工具 `photoframe`（规范 §11.3）和本地 stdio MCP 服务器 `photoframe mcp serve`（§11.4）。
/// 命令实现在 `PhotoFrameCLI` 库里，可执行文件只负责进程级的事（信号、标准输出、退出码），测试可以在进程内直接调用命令。
let package = Package(
    name: "photoframe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "photoframe", targets: ["photoframe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        // 官方 Swift MCP SDK，固定版本（§11.4「以实施时官方稳定版本为准」）；支持协议 2025-11-25 及更早版本。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // MCP SDK 的依赖；自己的 stdio 传输（MCPStdioTransport）实现 `Transport` 要用它的 `Logger`。
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(path: "../../Packages/PhotoFrameCore"),
        .package(path: "../../Packages/PhotoFrameStorage"),
        .package(path: "../../Packages/PhotoFrameApplication"),
        .package(path: "../../Packages/PhotoFrameRendering"),
    ],
    targets: [
        .target(
            name: "PhotoFrameCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
            ]),
        .executableTarget(name: "photoframe", dependencies: ["PhotoFrameCLI"]),
        .testTarget(
            name: "PhotoFrameCLITests",
            dependencies: [
                "PhotoFrameCLI",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
                // 让 `swift test` 先构建可执行文件，端到端测试以子进程运行它。
                "photoframe",
            ]),
    ]
)
