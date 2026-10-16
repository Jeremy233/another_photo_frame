// swift-tools-version: 6.2
// 色彩 PoC：实验代码，不属于正式的 Packages/ 目录。
import PackageDescription

let package = Package(
    name: "ColorPoC",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "colorpoc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
