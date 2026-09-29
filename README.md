# QuietChat - 只言片语

让微信只露出你需要的那几个聊天。

打开微信电脑版时，QuietChat 用一块遮罩盖住左侧聊天列表，只留几个快捷入口，比如「文件传输助手」。想看全部聊天时输入密码解锁；关掉微信窗口后，它会自动重新锁定。它要做的是在"随手打开微信"和"被无关消息吸走注意力"之间加一点阻力，不是一把真正的锁。

> **状态**：v1 开发中。目前只支持 macOS，Windows 版在规划中。

## 工作方式与隐私

- 不修改、不注入微信，只是在微信窗口上方显示一个遮罩窗口。
- 不联网，不读取聊天内容。
- v1 只需要「辅助功能」权限，用来获取微信窗口的位置、监听窗口的移动和关闭。

## 在 macOS 上构建运行

要求 macOS 14 及以上、Xcode 26 及以上。

1. 用 Xcode 打开 `macos/QuietChat.xcodeproj`，选择 `QuietChat` scheme，按 ⌘R 运行。
   也可以用命令行：
   ```bash
   xcodebuild -project macos/QuietChat.xcodeproj -scheme QuietChat -configuration Debug -derivedDataPath macos/build build
   open macos/build/Build/Products/Debug/QuietChat.app
   ```
2. 首次运行会弹出辅助功能授权提示。到「系统设置 → 隐私与安全性 → 辅助功能」里打开 QuietChat。
3. 在遮罩的密码框里输入默认密码 `1234567890` 解锁，然后点菜单栏的 QuietChat 图标，选「校准遮罩位置…」，拖动蓝框的左、右、上三条边，对齐微信的聊天列表。

密码框默认明文显示，右侧的按钮可以切换为隐藏输入，下次沿用你最后的选择。解锁后可以在菜单里「修改密码…」；忘了密码时，选菜单里的「恢复默认密码…」即可，锁定状态下也能用。

### 重新编译后授权失效？

默认使用本机临时签名。每次重新编译签名都会变，系统会把它当成新应用，辅助功能授权随之失效。

- **根本解决**：把 `macos/Configs/Local.xcconfig.example` 复制为 `Local.xcconfig`，按里面的说明填写一个固定的签名身份（免费 Apple ID 的开发证书，或自建证书都可以）。
- **临时办法**：在辅助功能列表里用「−」删掉 QuietChat，重新运行后再授权一次。

## 测试

```bash
swift test --package-path macos/QuietChatCore
```

## 了解更多

- 架构、模块划分与行为规则：[docs/architecture.md](docs/architecture.md)
- 为什么各平台分别原生实现：[docs/adr/0001-native-per-platform.md](docs/adr/0001-native-per-platform.md)
