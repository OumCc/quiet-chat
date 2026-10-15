# 发布与应用更新

QuietChat 1.1.0 起使用 Sparkle 2.10.0；自动检查需先取得同意，每次安装需用户确认。应用仍用临时签名，更新归档和清单由固定 EdDSA 密钥校验。系统首次放行和升级后重新授权限制仍然存在。

## 更新密钥

本机专用钥匙串 account 为 `io.github.OumCc.QuietChat.updates`。公钥配置在 `macos/Configs/QuietChat.xcconfig` 的 `SPARKLE_PUBLIC_ED_KEY`；私钥不得进入仓库、构建日志或安装包。

依赖首次解析后，可以读取现有公钥（仅输出公钥）：

```bash
macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account io.github.OumCc.QuietChat.updates -p
```

使用仓库外绝对路径备份现有私钥，脚本不覆盖文件，权限为 600：

```bash
bash tools/release/export-update-key.sh "$HOME/Library/Application Support/QuietChat/release-keys/sparkle-ed25519.key"
```

在 GitHub 仓库「Settings → Secrets and variables → Actions」增加 repository secret `SPARKLE_ED25519_PRIVATE_KEY`，值为该备份文件中的 Base64 文本。如果本机已有 GitHub CLI，可直接从文件传入，避免把私钥粘到命令行：

```bash
gh secret set SPARKLE_ED25519_PRIVATE_KEY --repo OumCc/quiet-chat < "$HOME/Library/Application Support/QuietChat/release-keys/sparkle-ed25519.key"
```

在其它电脑恢复时，用 Sparkle `generate_keys --account io.github.OumCc.QuietChat.updates -f <备份文件>` 导入原密钥；不要重新生成一把不同的密钥替代。已有临时签名客户端依赖原公钥，密钥丢失需要用户手动安装新的信任版本。

## 正式发布

1. 修改根目录 `MARKETING_VERSION` 为新的稳定 `x.y.z` 版本，提交后由维护者推送相同的 `v<版本号>` tag。首个更新器版本为 1.1.0；发布构建号沿用此工作流的 GitHub 运行编号，后续应递增。
2. Actions 运行单测、解析锁定依赖、构建 arm64+x86_64 应用，显式重签主应用以保留 runtime，并严格检查嵌套签名，再打包完整 DMG 和 SHA-256。
3. 用私钥生成 appcast 与版本说明签名，再用应用内公钥验证归档长度、签名、版本和最低系统要求。任一失败均停止。
4. 全部资产上传草稿后才公开并设置 latest。固定源为 `https://github.com/OumCc/quiet-chat/releases/latest/download/appcast.xml`；安装包指向相同 tag 下的固定下载地址。

手动 `workflow_dispatch` 不需要私钥，只提供 DMG artifact，不公开 Release 或更新清单。客户端要求已签名清单且不启用签名失败超时降级；不要手工修改已签名文件或用同一 tag 替换资产。修复版本以新的更高构建号发布。

## 验证

```bash
swift test --package-path macos/QuietChatCore
xcodebuild -project macos/QuietChat.xcodeproj -scheme QuietChat -configuration Release -destination 'generic/platform=macOS' -derivedDataPath macos/build -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
codesign --verify --deep --strict macos/build/Build/Products/Release/QuietChat.app
```

真实安装使用独立密钥、应用标识及本地测试源，不改正式更新源或正式签名密钥。需要验证同意前/拒绝后无请求、后台提醒不抢焦点、每次下载需确认、取消/错误签名/归档损坏不替换、重定向下载成功、两构建实际替换重启和偏好保留。升级后权限引导条件由 Core 测试覆盖，并需在具备相应系统权限环境时人工确认。未具备设备或授权的项记录为未验证。

仓库提供隔离宿主、失败源与真实 Sparkle 回调验证（先完成 Debug 构建）：

```bash
python3 tools/release/test-update-release.py /private/tmp/quiet-chat-update-test
python3 tools/release/test-update-release.py /private/tmp/quiet-chat-update-test --serve
```

另开终端运行 `--probe`，验证错误签名、损坏、取消、无更新及重定向；`--check-offline` 验证已拒绝且检查到期时真实控制器启动无请求。这两个模式仅操作独立 bundle ID `io.github.OumCc.QuietChat.UpdateIntegration`。界面安装可打开生成的 `old/QuietChat Update Test.app`，允许检查后手动确认；新构建为 30002，旧构建为 30001。`--reset-host` 创建新的旧构建副本，`--reset-consent` 同时重置该测试域的首次选择。测试 HTTP 只监听本机，正式更新包没有此网络例外。

2026-10-13 在 macOS 26.5/Xcode 26.5 完成 73 项 Core 测试、通用构建、签名门禁、隔离宿主实际替换重启和下载回调场景。Intel/macOS 14 真机、系统重新授权及管理员批准界面尚未验证；完整记录见 [research.md](../openspec/changes/archive/2026-10-15-add-macos-auto-update/research.md)。
