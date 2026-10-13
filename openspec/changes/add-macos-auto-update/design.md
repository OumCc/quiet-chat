# macOS 更新技术设计

## 审阅摘要

采用 Sparkle 2.10.0 的标准更新窗口、安装器和 gentle reminders，避免自建安装器。AppKit 装配控制首次联网同意和权限引导；CI 使用相同工具签署并校验清单与完整 DMG。临时签名需关闭 Library Validation；其系统信任和重新授权限制保留。验证以单测、通用构建、签名检查和独立源双版本真实安装为准，不自动发布。

## 数据流与接口

AppDelegate 持有主线程 AppUpdateController。控制器包装 SPUStandardUpdaterController，实现 SPUUpdaterDelegate / SPUStandardUserDriverDelegate；菜单通过 StatusMenuDelegate 查询 canCheckForUpdates、automaticallyChecksForUpdates、availableUpdateVersion，以及检查/开关动作。状态变化回调刷新现有图标。更新状态不进入共享配置。

Info.plist 默认 SUEnableAutomaticChecks=NO，SUAutomaticallyUpdate=NO，SUAllowsAutomaticUpdates=NO，SUEnableSystemProfiling=NO。首次读取 Sparkle 的 SUEnableAutomaticChecks 用户偏好是否存在，弹本地同意窗口，再通过 Sparkle 属性保存；不在每次启动覆盖选择。检查间隔 86400 秒，调度交给 Sparkle。

后台 scheduled update 的展示决策返回不显示标准窗口；gentle reminder 回调保存版本并刷新模板图标。用户点击菜单时调用标准检查 API，将已有更新窗口带到前台；接受关注或会话结束时清除标记。下载忙碌时用 canCheckForUpdates 禁用检查入口。

## 签名、发布与版本

QuietChat.xcconfig 配置固定公钥和 HTTPS SUFeedURL；应用提供禁用 Library Validation 的 entitlement，Hardened Runtime 保留，Sparkle 不启用沙盒 XPC 服务。嵌入框架与签名锁定依赖，验证所有嵌套工具。

专用密钥通过 generate_keys 保存本机钥匙串；导出备份只写仓库外，私钥作为 SPARKLE_ED25519_PRIVATE_KEY GitHub Secret，通过 stdin 传给 Sparkle 工具。SUVerifyUpdateBeforeExtraction=YES，SURequireSignedFeed=YES，SUSignedFeedFailureExpirationInterval=0。签名完成后不得修改清单或说明。

release-macos.yml：稳定版本/tag 校验 → Core 测试 → 通用临时签名构建 → DMG/SHA-256 → 版本说明 → generate_appcast（maximum-deltas=0）→ 归档公钥/清单校验 → 草稿上传全部资产 → 公开 latest。签名工具取自固定 Sparkle 分发；客户端版本来自应用包。序列化发布，不取消已开始的发布。手动构建无需私钥、不公开更新清单。

首版 MARKETING_VERSION=1.1.0；构建号保留 GITHUB_RUN_NUMBER。旧用户手动安装首版。回滚通过更高构建号发布修复版本，不通过清单降级。

## 权限、错误与安装边界

纯逻辑更新偏好和权限提示策略放入 Core，以独立 UserDefaults suite 测试。启动时比较上次和当前构建号，更新记录后仅在构建变化及实际所需权限缺失时提示一次。首次安装继续原授权流程；升级提示不重复系统弹窗，“打开设置”复用现有授权入口。

只读挂载、应用转移或不可写位置由安装前检查及 Sparkle 原生授权错误处理，给出复制到应用程序或手动下载路径。后台错误仅日志；手动检查由标准窗口显示错误。更新窗口包含重启、遮罩暂时停止、未保存编辑和重新授权说明。

README 和 architecture 删除全面不联网承诺，限定为更新检查/下载，不上传聊天/密码/名单，不上报系统信息。

## 验证

- Core 测试首次偏好、拒绝/允许持久化、提醒清理、权限提示一次性和所需键盘访问条件。
- Debug / Release 构建、arm64+x86_64、代码签名及嵌套 Sparkle 工具检查。
- 独立测试密钥、应用标识和本地源验证两版本实际下载/替换/重启；本地 HTTP 仅用于测试副本，正式包仍固定 HTTPS。
- 失败源覆盖无更新、取消、错误密钥、篡改归档、清单篡改和重定向；旧应用、配置和偏好保留。
- 没有设备/凭据的验收明确记录，不以构建冒充真实测试。

无尚待决策的 Blocking 问题。
