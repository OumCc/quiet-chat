# 实施任务

## 审阅摘要

- 实施目标：按 design 实现 `masking-mode`、`chat-whitelist`、`precise-masking` 三份规格，整块遮挡的行为不变。
- 依赖顺序：Core 配置与名单 → Core 匹配、切分、指纹、状态、规划 → 识别模块 → 应用外壳的截图与精准遮挡流程 → 菜单、名单窗口与装配 → 文档 → 验证。
- 完成定义：所有任务勾选；单测、构建、本机验收、整块遮挡回归、OpenSpec 严格校验全部通过；真实截图没有进入仓库。
- 最终验证集合：`swift test --package-path macos/QuietChatCore`；`xcodebuild` 的 Debug 和 Release 构建；启动冒烟；本机真实截图校准；用户按规格场景验收；M1、M2 回归清单；`openspec validate add-precise-masking-mode --strict --no-interactive`。

## 1. Core：配置与名单

- [ ] 1.1 在 `AppConfig.swift` 中新增 `MaskMode`（`full`/`precise`，遇到未知取值按 `full` 解码），以及 `maskMode`、`whitelist`、`preciseListColumn` 三个字段和 `listColumnLayout(for:)`；精准遮挡未校准时，按（`listColumn.leftInset`，0，`listColumn.width`）推导 — 验证：新增单测覆盖默认值、字段缺失、未知取值和 D-007 的推导示例（60/246/242 → 60/0/242），全部通过。
- [ ] 1.2 在 `shared/config.schema.json` 中新增 `maskMode`、`whitelist`、`preciseListColumn`，并在 `AppConfigTests` 的全字段配置里加入这三个字段 — 验证：`encodedFieldsMatchSharedSchema` 通过。
- [ ] 1.3 新增 `ChatWhitelist.normalized(_:)`：去掉首尾空白，丢弃空行，按首次出现的顺序去重 — 验证：单测覆盖 chat-whitelist 规格"含空行和重复名称"的场景，以及顺序保持，全部通过。

## 2. Core：匹配、切分、指纹、状态、规划

- [ ] 2.1 新增 `ChatNameMatcher`：`normalize` 做 NFC 规范化、去掉表情和首尾空白；`isWhitelisted` 按完全一致匹配，并处理截断（"…"或"..."，前缀至少 2 个字符） — 验证：单测覆盖 precise-masking 规格中名称匹配、截断、重名的全部场景，以及前缀不足 2 个字符时不匹配。
- [ ] 2.2 新增 `TextBox`、`ListRow`、`ListRowParser.parse(_:columnWidth:)`，按 design 的"行切分"规则实现，参数定义为常量 — 验证：合成文字框单测覆盖有预览和无预览的行、右侧时间框、头像角标、少于 3 行时回退到 64 pt、名称末尾时间被去掉，全部通过。
- [ ] 2.3 新增 `ContentFingerprint`：输入 BGRA 帧（1 倍分辨率），按 design 的"变化检测"规则实现，参数定义为常量 — 验证：合成帧单测覆盖以下情况：整行底色改变（模拟悬停）不算变化；文字改变、整体平移、条数不同都算变化。
- [ ] 2.4 新增 `PreciseRevealState`：`contentChanged`、`beginRecognition`、`finishRecognition(generation:bands:)`、`reset` — 验证：单测覆盖变化即清空、过期的识别结果被丢弃、`reset` 后旧编号失效。
- [ ] 2.5 为 `MaskPlanner.plan/decide` 新增参数 `revealed` 和 `reservedBottomHeight`，默认值下行为不变 — 验证：现有 `MaskPlannerTests` 不做修改仍全部通过；新增单测覆盖露出带区的裁剪、底部条不开洞、与遮挡洞合并。

## 3. 识别模块

- [ ] 3.1 在 `macos/QuietChatCore/Package.swift` 中新增 `QuietChatDetection` 的 library、target 和 testTarget；实现 `TextRecognizer.recognize(_:scale:customWords:)`，Vision 参数与验证脚本一致（`.accurate`、`zh-Hans`/`en-US`、开启语言纠正、`customWords`），输出列表栏坐标下的 `[TextBox]`（左上角为原点，单位 pt） — 验证：`swift build --package-path macos/QuietChatCore` 通过，没有警告。
- [ ] 3.2 在 `QuietChatDetectionTests` 中用 CoreText 生成合成列表图片（深色、浅色、一行悬停、一个截断名称），依次跑 `TextRecognizer`、`ListRowParser`、`ChatNameMatcher` — 验证：白名单行全部被找到，带区与真实行的交并比大于 0.8，非白名单行不匹配。
- [ ] 3.3 在 `macos/QuietChat.xcodeproj/project.pbxproj` 中为应用目标加入 `QuietChatDetection` 包产品依赖 — 验证：`xcodebuild` Debug 构建通过，没有警告。

## 4. 应用外壳：截图与精准遮挡流程

- [ ] 4.1 新增 `App/ScreenRecordingPermission.swift`（`isGranted`、`request`、`openSystemSettings`） — 验证：构建通过；本机在没有权限时调用 `isGranted` 返回 false。
- [ ] 4.2 新增 `Capture/ListCapture.swift`：按主窗口编号找到 `SCWindow`，建立裁到列表栏（不含底部条）的 1 倍分辨率流，最多 10 帧/秒；在截图队列上计算指纹，把"变化"事件切回主线程；提供原生分辨率的静帧截取；窗口编号或列表栏矩形变化时更新流 — 验证：本机在精准遮挡锁定时，日志记录帧数和变化次数，且不含聊天名称；画面静止时帧数不再增长。
- [ ] 4.3 新增 `Masking/PreciseRevealController.swift`：按条件启停截图；150 ms 稳定计时；识别在后台任务中进行，2 秒超时后 1 秒重试；监听列表栏内的滚轮；窗口大小或列表栏矩形变化时让露出的行失效；截图失败时 `reset` 并每 5 秒重试；输出窗口坐标下的露出带区 — 验证：本机滚动、新消息、切到通讯录时，0.3 秒内盖住，稳定后重新露出；悬停和点击不会盖住；解锁或关闭窗口后，日志显示截图已停止。
- [ ] 4.4 修改 `MaskController`（`revealedBands`、`reservedBottomHeight`、`lockControlsPlacement`，并传给 `MaskPlanner`，校准时不开露出洞）和 `MaskView`（`LockControlsPlacement` 的两组约束；底部条模式下不画居中标题） — 验证：整块遮挡的外观和密码框位置与现在相同；精准遮挡下密码框位于底部 56 pt 条中，落在条内的白名单行部分保持遮住。

## 5. 应用外壳：菜单、名单窗口与装配

- [ ] 5.1 新增 `App/WhitelistEditor.swift`（`WhitelistEditorController`：SwiftUI `TextEditor`，保存和取消，`close()`，打开时激活应用） — 验证：本机保存后的名单经 `ChatWhitelist.normalized` 整理并写入配置；取消不写入；调用 `close()` 后未保存的修改被丢弃。
- [ ] 5.2 修改 `StatusMenuController`：新增"遮挡方式"分组（两个单选项和"编辑白名单…"）、"授予屏幕录制权限…"、精准遮挡的状态文字，以及新的锁定提示；`StatusMenuDelegate` 增加对应的属性和方法 — 验证：本机核对菜单项的可用状态：锁定时可以切换遮挡方式；"编辑白名单…"只在精准遮挡且解锁时可用；缺少权限时显示授权项。
- [ ] 5.3 修改 `AppDelegate`：读取遮挡方式和名单；切换时保存并立即生效；切到精准遮挡时，没有权限就申请，名单为空且已解锁就打开名单窗口；在精准遮挡下校准时写入 `preciseListColumn`；锁定时关闭名单窗口；把 `PreciseRevealController` 的输出交给 `MaskController` — 验证：本机按 masking-mode 和 chat-whitelist 规格逐条核对场景，全部通过。

## 6. 文档

- [ ] 6.1 按 design 的"文档修改"更新 `docs/architecture.md`（删除 M3 和快捷入口，新增精准遮挡规则、配置字段、屏幕录制权限，更新模块表、里程碑和待验证问题） — 验证：全文不再出现快捷入口；精准遮挡规则与三份规格一致。
- [ ] 6.2 按 design 的"文档修改"更新 `README.md`（功能、隐私说明、屏幕录制权限、升级后需要重新授权、后续计划） — 验证：逐项与实现核对一致；README 不再声称精准遮挡"不读取聊天内容"。

## 7. 验证

- [ ] 7.1 运行 `swift test --package-path macos/QuietChatCore` — 验证：Core 和 Detection 的全部测试通过。
- [ ] 7.2 `xcodebuild` 分别以 Debug 和 Release 构建，然后做启动冒烟 — 验证：没有错误和警告；新实例能启动并替换旧实例，没有新的崩溃报告。
- [ ] 7.3 用户在本机提供深色、浅色、悬停、选中、长名称五种真实截图，用它们校准行切分和指纹的参数（截图留在本机，不入库） — 验证：校准后，这些截图中的白名单行全部被正确识别，非白名单行都不露出。
- [ ] 7.4 用户在本机按 precise-masking、masking-mode、chat-whitelist 三份规格的场景验收精准遮挡 — 验证：全部场景通过；系统日志中没有聊天名称。
- [ ] 7.5 在整块遮挡模式下重新核对 M1、M2 的验收清单 — 验证：全部通过，行为与本变更之前相同。
- [ ] 7.6 运行 `fnm exec --using v22.22.1 openspec validate add-precise-masking-mode --strict --no-interactive` — 验证：校验通过。
