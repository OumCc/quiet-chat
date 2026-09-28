// swift-tools-version: 6.0
// QuietChatCore：macOS 端的纯逻辑层（坐标换算、列表栏布局、遮罩决策、主窗口挑选、配置模型）。
// 边界：只依赖 Foundation / CoreGraphics，不引用 AppKit 与辅助功能接口，可以直接 `swift test`。
// Windows 端的 QuietChat.Core 按同样的职责与命名实现，见 docs/architecture.md。

import PackageDescription

let package = Package(
    name: "QuietChatCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuietChatCore", targets: ["QuietChatCore"]),
    ],
    targets: [
        .target(name: "QuietChatCore"),
        .testTarget(name: "QuietChatCoreTests", dependencies: ["QuietChatCore"]),
    ]
)
