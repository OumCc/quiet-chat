# macOS 自动更新调研

## 审阅摘要

- 缘由：[USER] GitHub 能发布 DMG，但已安装客户端尚不能自行更新。
- 目标：[USER] 首次征求联网检查同意，菜单栏提醒，确认后安全安装并重启，必要时引导重新授权。
- 结论：[CODE] 当前为原生 AppKit、非沙盒、Hardened Runtime 和临时签名；[API] Sparkle 支持 EdDSA 更新包及清单验证、标准安装器和 gentle reminders。
- 边界：[USER] 使用 GitHub Releases，首版 1.1.0；不接入 Developer ID、公证、增量包或后台静默安装。
- 待确认项：无 OPEN Blocking 问题；密钥配置及真实双版本安装必须在交付验证中明确记录。
- 下一步：[USER] 2026-10-13 已明确要求实施下列已确认计划；OpenSpec 严格校验后转入实施，无需重复请求方案批准。

## 输入清单

| 来源 | 格式/日期 | 位置 | 状态 |
| --- | --- | --- | --- |
| 用户实现计划及四项选择 | Markdown，2026-10-13 | 本聊天 | 已批准 |
| 工程与应用装配 | Swift / Xcode | AppDelegate、StatusMenuController、AccessibilityPermission、QuietChat.xcodeproj | 已检查 |
| 发布配置 | YAML / xcconfig | release-macos.yml、Version.xcconfig | 已检查 |
| Sparkle 2.10.0 | 官方 API / 源码 | https://sparkle-project.org/documentation/ | 已检查 |
| 项目规则与架构 | Markdown | 用户提供的 AGENTS.md、docs/architecture.md | 已检查 |

## 需求与视觉证据

[USER] 同意自动检查之前无更新联网；拒绝后可以手动检查；自动检查每天一次，发现更新只标记现有菜单栏图标。用户点击后使用标准更新窗口，并自行确认安装。没有提供需要还原的原型；沿用现有 AppKit 菜单与 Sparkle 标准界面。

## 调研基线与影响

| 证据 | 位置/符号 | 当前行为与影响 |
| --- | --- | --- |
| [CODE] | AppDelegate.applicationDidFinishLaunching | 加载配置、创建菜单、检查权限，没有更新装配 |
| [CODE] | StatusMenuController.updateIcon / menuNeedsUpdate | 图标表达锁定状态；版本为只读菜单项，新增标记不能覆盖锁定语义 |
| [CODE] | AccessibilityPermission.isGranted / canPostEvents | AX 与键盘合成访问分别核对，升级后不得自动授予系统权限 |
| [CODE] | project.pbxproj | Hardened Runtime=YES、App Sandbox=NO；需关闭 Library Validation 以加载临时签名 Sparkle |
| [CODE] | release-macos.yml | v* tag 构建通用 DMG，构建号为 GITHUB_RUN_NUMBER，尚无签名密钥和更新清单 |
| [CODE] | Version.xcconfig / git tag | 根目录版本 0.1.0，本地有 v1.0.0；首版更新到 1.1.0 |
| [CODE] | README、架构边界 | 声明不联网；必须调整为仅更新检查和安装联网，聊天数据不上传 |

## 契约映射

| 动作 | 输入/状态 | 结果 | 依据 |
| --- | --- | --- | --- |
| 首次开启更新 | 本地同意或拒绝 | Sparkle UserDefaults 保存选择；不改共享 JSON | [USER] |
| 后台检查 | 已同意、距上次检查至少 24 小时 | 获取已签名 appcast；可用版本显示菜单标记 | [USER][API] |
| 安装 | 用户点击并确认、有效签名 | Sparkle 下载、验证、替换、退出并重启 | [USER][API] |
| 升级后启动 | 构建号变化、所需权限缺失 | 本版本一次重新授权提示，保留原菜单授权入口 | [USER][CODE] |
| 发布 tag | 版本匹配、有效私钥 | DMG 和已签名清单全部上传后公开 Release | [USER] |

## 问题与决策

| ID | 分类 | 状态 | 选项与影响 | 决策 |
| --- | --- | --- | --- | --- |
| Q-001 | Blocking | ANSWERED | 默认联网或首次征求同意，影响隐私与启动流程 | [USER] 首次询问后开启 |
| Q-002 | Blocking | ANSWERED | GitHub 或独立更新地址，影响托管及 CI | [USER] GitHub Releases，需要一次密钥配置 |
| Q-003 | Blocking | ANSWERED | 自动弹窗或菜单标记，影响微信焦点 | [USER] 菜单栏标记和菜单提示 |
| Q-004 | Blocking | ANSWERED | 保持版本或修正首版 | [USER] 1.1.0，不自动发布/tag |
| Q-005 | Documentation defect | DISCOVERED | 不联网说明与新增功能冲突 | [USER] 修正联网边界并说明授权代价 |

## 兼容与验收边界

[API] 固定 EdDSA 公钥必须随客户端分发；临时签名不能作为密钥丢失后的自动信任兜底。清单与归档均要求签名，验证失败不得安装。现有用户先手动安装一次 1.1.0。配置 schema 不变；更新偏好和启动构建号保存在应用 UserDefaults。

[USER] 测试须覆盖同意/拒绝、菜单标记、损坏/错误签名、下载取消及重定向、实际双版本替换重启和重新授权条件。没有测试设备或发布凭据的部分应标记未验证，不能用构建代替真实安装。

## 就绪检查

- [x] 已接收完整计划并记录来源。
- [x] 已检查现有客户端、发布链路、权限及签名。
- [x] 无必需但未提供的视觉材料。
- [x] 所有 Blocking 选择已由用户确认。
- [x] 用户已明确批准实施，后续产物可创建。

## 实施验收记录（2026-10-13）

| 检查 | 结果与证据 |
| --- | --- |
| Core 回归 | `swift test --package-path macos/QuietChatCore`，73 项测试、12 个 suite 通过，含检查选择、提醒清理和权限条件 |
| 应用构建 | Xcode 26.5，Debug 与 Release 通过；Release 主程序包含 x86_64、arm64 |
| 应用签名 | `codesign --verify --deep --strict` 通过；重签后 flags 为 adhoc,runtime，含禁用 Library Validation entitlement |
| 发布门禁 | 独立测试密钥下生成清单成功，错误私钥与客户端公钥不匹配时阻止发布；篡改归档及清单分别验证失败 |
| 真实升级 | macOS 26.5 隔离宿主运行真实 AppUpdateController；标准窗口包含确认按钮和重启说明。安装副本从 30001 替换并重启为 30002，磁盘 Info.plist 和运行窗口一致，偏好与配置标记保留 |
| 下载失败与取消 | Sparkle 公共 user driver 回调宿主实际运行 wrong-key、tampered-feed、no-update、corrupt、slow、redirect 六个场景，均符合预期，旧构建保持 30001 |
| 拒绝检查 | 真实 AppUpdateController 宿主保存 false 并清除上次检查时间，启动后无新增请求，选择仍为 false |
| 工作流 | Ruby 标准 YAML 解析及所有 run 块 `bash -n` 通过；发布脚本语法检查通过 |
| 仓库安全 | 仓库内无生成的 .key/.pem；生产私钥保存在专用钥匙串 account 并备份到仓库外，未写入日志或产物 |

验证宿主及源可由 `tools/release/test-update-release.py` 重建。桌面控制服务在部分后续操作中返回 timeoutReached，因此失败、取消和重定向通过 Sparkle 公开回调执行，未将这些回调测试声称为按钮界面测试。

外部前置条件：本机没有 GitHub CLI 或可用凭据管理连接，本次未代设仓库 `SPARKLE_ED25519_PRIVATE_KEY`；维护者发布前需确认其已正确配置，具体导入步骤见 docs/releases.md。未创建 Release 或推送 tag。Intel 真机、macOS 14 真机、系统权限重新授权界面和需要管理员批准的安装仍未验证；权限判断组合已通过 Core 测试。
