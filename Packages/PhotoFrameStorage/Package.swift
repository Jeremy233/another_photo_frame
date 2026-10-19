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
            // 没有资源文件：平台配置编译进程序（D-126），单独复制出来的 photoframe 可执行文件不依赖资源包。
            dependencies: [.product(name: "PhotoFrameCore", package: "PhotoFrameCore")]),
        .testTarget(name: "PhotoFrameStorageTests", dependencies: ["PhotoFrameStorage"]),
    ]
)
