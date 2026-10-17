// swift-tools-version: 6.2
import PackageDescription

// 应用的全部代码：状态与 view model（PhotoFrameMacModel，可测试、不依赖 SwiftUI）和界面（PhotoFrameMacUI）。
// Xcode 工程 ../PhotoFrameMac.xcodeproj 只负责打包 .app、Info.plist 与 entitlements。
let package = Package(
    name: "PhotoFrameMacKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoFrameMacUI", targets: ["PhotoFrameMacUI"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/PhotoFrameCore"),
        .package(path: "../../../Packages/PhotoFrameStorage"),
        .package(path: "../../../Packages/PhotoFrameRendering"),
        .package(path: "../../../Packages/PhotoFrameApplication"),
    ],
    targets: [
        .target(
            name: "PhotoFrameMacModel",
            dependencies: [
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
            ]),
        .target(
            name: "PhotoFrameMacUI",
            dependencies: [
                "PhotoFrameMacModel",
                .product(name: "PhotoFrameCore", package: "PhotoFrameCore"),
                .product(name: "PhotoFrameStorage", package: "PhotoFrameStorage"),
                .product(name: "PhotoFrameRendering", package: "PhotoFrameRendering"),
                .product(name: "PhotoFrameApplication", package: "PhotoFrameApplication"),
            ]),
        .testTarget(name: "PhotoFrameMacModelTests", dependencies: ["PhotoFrameMacModel"]),
        .testTarget(name: "PhotoFrameMacUITests", dependencies: ["PhotoFrameMacUI"]),
    ]
)
