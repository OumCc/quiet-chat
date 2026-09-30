// swift-tools-version: 6.0
// QuietChatCore：macOS 端的纯逻辑层（坐标换算、列表栏布局、遮罩决策、主窗口挑选、配置模型，以及精准遮挡的名称匹配、行切分、变化检测）。
// 边界：只依赖 Foundation / CoreGraphics，不引用 AppKit 与辅助功能接口，可以直接 `swift test`。
// Windows 端的 QuietChat.Core 按同样的职责与命名实现，见 docs/architecture.md。
// QuietChatDetection：用 Vision 识别列表画面里的文字。单独成库，Core 不必依赖识别框架；
// 它的测试用合成图片跑完整的"识别 → 切分 → 匹配"流程。

import PackageDescription

let package = Package(
    name: "QuietChatCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuietChatCore", targets: ["QuietChatCore"]),
        .library(name: "QuietChatDetection", targets: ["QuietChatDetection"]),
    ],
    targets: [
        .target(name: "QuietChatCore"),
        .testTarget(name: "QuietChatCoreTests", dependencies: ["QuietChatCore"]),
        .target(name: "QuietChatDetection", dependencies: ["QuietChatCore"]),
        .testTarget(name: "QuietChatDetectionTests", dependencies: ["QuietChatDetection"]),
    ]
)
