# 技术设计

## 审阅摘要

- 采用方案与原因：在现有"窗口跟踪 + 透明洞遮罩"之上，增加一条"读取画面 → 识别 → 匹配 → 开洞"的流水线。
  - 读取画面：用 ScreenCaptureKit 读取微信主窗口里的列表栏。具体的截图方式待定（Q-014），见"截图"一节。
  - 判断列表是否变化：逐帧计算"去底色指纹"。悬停只小幅改变底色，不会被当成变化；选中行的底色变化很大（深色模式下变成绿色），会被当成变化（D-014）。
  - 识别：用 Vision OCR，按行间距切分出每一行。
  - 匹配规则、行切分、指纹、"先遮后露"状态都写成纯逻辑，用单元测试覆盖。
  - 整块遮挡走原来的代码路径，不改动。
- 涉及边界：
  - Core：配置、名称匹配、行切分、指纹、状态、遮罩规划。
  - 本地包新增 `QuietChatDetection` target，封装 Vision。
  - 应用外壳：截图、屏幕录制权限、白名单窗口、菜单、遮罩视图。
  - 文档。
- 关键兼容约束：旧配置读出来是整块遮挡；`schemaVersion` 不变。整块遮挡时，`MaskPlanner` 的输入输出与现在完全相同，现有单测保持通过。部署目标仍是 macOS 14，`SCScreenshotManager` 从 14 起可用。
- 验证方式：
  - Core 单测。
  - `QuietChatDetection` 用合成的列表图片跑完整识别流程：深色、浅色、悬停、截断名称。
  - 用户在本机按清单验收（真实截图不入库）。
  - 整块遮挡回归。
- 主要风险：
  - 真实画面下识别和行切分的参数需要校准。
  - macOS 可能定期要求重新确认屏幕录制权限。
  - Q-011 未采纳时，已露出的行会随任何新消息闪一下。
  - 截图和识别带来的 CPU 开销。

## 背景与约束

- [CODE] 微信 4.x 的辅助功能接口读不到列表内容，只能靠识别画面（`docs/architecture.md` §2）。可行性验证脚本用 Vision 在真实深色截图上认对了 6/6 个名称（V-01）。
- 原则：宁可多遮，不漏出。识别不出、没权限、名单为空、识别超时，都按"遮住"处理（D-001、D-008、D-011）。
- 隐私：画面只在内存中处理，不落盘，不联网，日志不记录聊天名称（D-011）。
- 平台：macOS 14+、Swift 6、临时签名分发（README "下载安装"）。

## 目标与非目标

- 目标：实现 `masking-mode`、`chat-whitelist`、`precise-masking` 三份规格中的全部 Requirement。
- 非目标：按置顶识别；黑名单；快捷入口；Windows 版；Q-011 的闪动优化（本设计保留实现的余地，但默认不启用）。

## 当前与目标流程

当前流程（[CODE]）：

```
AX 事件 / RefreshDriver（事件、按下鼠标时逐帧、每 0.25 秒兜底）
  → WeChatWindowTracker.snapshot()（外框、显示状态、是否在所有桌面、遮挡窗口）
  → AppDelegate.refresh()：LockState.autoLockIfNeeded → MaskController.update
  → MaskPlanner.decide(snapshot, layout) → 洞 = 遮挡窗口
```

目标流程（整块遮挡不变；精准遮挡在此基础上增加）：

```
AppDelegate.refresh()
  → PreciseRevealController.update(条件, 快照)       // 条件：精准遮挡 ∧ 锁定 ∧ 可见 ∧ 已授权 ∧ 名单非空
      满足条件 → ListCapture 截取列表栏（每秒最多 10 帧，画面静止时系统不推送新帧）
        每帧：ContentFingerprint 与上一帧比较
          有变化 → PreciseRevealState.contentChanged()：已露出的行立即全部清空（被盖住）
                   重新计时 150 ms
          150 ms 内无新变化 → 截取原生分辨率静帧 → TextRecognizer → ListRowParser → ChatNameMatcher
                   → PreciseRevealState.finishRecognition(本轮编号, 带区)
                     编号仍是最新 → 露出这些带区；否则丢弃
        列表栏内的滚轮事件 / 窗口大小变化 → contentChanged()
      不满足条件 → 停止截图，PreciseRevealState.reset()
  → MaskController.update(快照, 露出带区[窗口坐标], 底部条高度)
  → MaskPlanner.decide(…, revealed, reservedBottomHeight)
       洞 = 遮挡窗口 ∪（露出带区 ∩ 遮罩 − 底部遮挡条）
```

露出带区按窗口坐标保存，渲染时再加上窗口原点，所以移动窗口时带区直接跟着走（D-012③）。

## 修改地图

| 区域 | 路径与符号 | 当前职责 | 计划变更 | 证据或决策 |
| --- | --- | --- | --- | --- |
| Core 配置 | `macos/QuietChatCore/Sources/QuietChatCore/AppConfig.swift` `AppConfig` | 4 个字段，缺失字段取默认值 | 新增 `maskMode: MaskMode`（默认 `.full`）、`whitelist: [String]`（默认 `[]`）、`preciseListColumn: ListColumnLayout?`（默认 `nil`）；新增 `listColumnLayout(for:)`，在精准遮挡且 `preciseListColumn == nil` 时返回（`listColumn.leftInset`，0，`listColumn.width`） | D-001、D-004、D-007、D-011 |
| Core 配置 | 同上，新增 `MaskMode` | — | `enum MaskMode: String, Codable { case full, precise }`；遇到未知取值时按 `.full` 解码 | D-011 |
| 配置 schema | `shared/config.schema.json` | 4 个字段 | 新增 `maskMode`（枚举 `full`/`precise`，默认 `full`）、`whitelist`（字符串数组）、`preciseListColumn`（结构同 `listColumn`） | D-011 |
| Core 名单 | 新增 `QuietChatCore/.../ChatWhitelist.swift` `ChatWhitelist.normalized(_:)` | — | 保存前整理：去掉首尾空白，丢弃空行，按首次出现的顺序去重 | chat-whitelist 规格 |
| Core 匹配 | 新增 `QuietChatCore/.../ChatNameMatcher.swift` `ChatNameMatcher` | — | `normalize(_:)`、`isWhitelisted(_:whitelist:)`，规则见"名称匹配" | D-002 |
| Core 行切分 | 新增 `QuietChatCore/.../ListRowParser.swift` `TextBox`、`ListRow`、`ListRowParser.parse(_:columnWidth:)` | — | 把 OCR 文字框切分成行，得到"名称 + 带区" | D-001 |
| Core 变化检测 | 新增 `QuietChatCore/.../ContentFingerprint.swift` `ContentFingerprint` | — | 去底色指纹，规则见"变化检测" | D-003、D-012① |
| Core 状态 | 新增 `QuietChatCore/.../PreciseRevealState.swift` `PreciseRevealState` | — | 先遮后露：变化时清空；识别结果带编号，过期的丢弃 | D-003、D-012② |
| Core 规划 | `QuietChatCore/.../MaskPlanner.swift` `MaskPlanner.plan/decide` | 洞 = 遮挡窗口 | 新增参数 `revealed: [CGRect] = []`（全局坐标）、`reservedBottomHeight: CGFloat = 0`；默认值下行为与现在相同 | D-006 |
| 识别 | 新增 target `QuietChatDetection`：`Sources/QuietChatDetection/TextRecognizer.swift` `TextRecognizer.recognize(_:scale:customWords:)`；`Package.swift` 新增 library、target、testTarget | — | 调用 Vision 识别文字，输出 `[TextBox]`（列表栏坐标，左上角为原点，单位 pt） | D-001、D-010 |
| 截图 | 新增 `macos/QuietChat/Capture/ListCapture.swift` `ListCapture` | — | 管理 SCStream（单窗口、裁到列表栏）；在截图队列上逐帧算指纹；按需截取静帧 | D-003 |
| 权限 | 新增 `macos/QuietChat/App/ScreenRecordingPermission.swift` | — | `isGranted`（`CGPreflightScreenCaptureAccess`）、`request()`（`CGRequestScreenCaptureAccess`）、`openSystemSettings()` | D-008、D-011 |
| 精准遮挡流程 | 新增 `macos/QuietChat/Masking/PreciseRevealController.swift` | — | 根据条件启停截图；判断画面稳定；调度识别；监听滚轮；截图失败时退化；输出露出带区（窗口坐标） | D-003、D-008、D-011 |
| 遮罩控制 | `macos/QuietChat/Masking/MaskController.swift` `MaskController` | 单一布局；洞 = 遮挡窗口 | 新增 `revealedBands`（窗口坐标）、`reservedBottomHeight`、`lockControlsPlacement`；`render()` 把前两者传给 `MaskPlanner`；校准时不开露出洞 | D-006、D-007 |
| 遮罩视图 | `macos/QuietChat/Masking/MaskView.swift` `setUpLockControls()`、`draw(_:)` | 密码框居中，标题在中间偏上 | 新增 `LockControlsPlacement`：`.centered`（整块遮挡，保持现状）/`.bottomStrip(height:)`（精准遮挡：密码框在底部条中垂直居中，不画居中标题）；切换时换用对应的约束组 | D-006 |
| 装配 | `macos/QuietChat/App/AppDelegate.swift` | 刷新、锁定、配置 | 读取模式和名单；切换模式；申请权限；首次引导；按模式保存校准；锁定时关闭名单窗口；把 `PreciseRevealController` 的输出交给 `MaskController` | D-004～D-008、D-012 |
| 菜单 | `macos/QuietChat/App/StatusMenuController.swift` `StatusMenuDelegate`、`menuNeedsUpdate(_:)` | 无模式相关菜单项 | 新增"遮挡方式"分组、屏幕录制授权项、状态文字；锁定时的提示改为"解锁后才能修改密码、校准和编辑白名单" | D-004、D-005、D-008 |
| 名单窗口 | 新增 `macos/QuietChat/App/WhitelistEditor.swift` `WhitelistEditorController` | — | 用 SwiftUI `TextEditor` 编辑，每行一个名称；提供保存和取消；可被外部关闭 | D-004、D-005、D-012⑤ |
| 工程 | `macos/QuietChat.xcodeproj/project.pbxproj` | 只依赖 `QuietChatCore` 产品 | 新增 `QuietChatDetection` 的包产品依赖（`XCSwiftPackageProductDependency`、`PBXBuildFile`、Frameworks 阶段） | — |
| 文档 | `docs/architecture.md`、`README.md` | 仍有 M3；隐私说明写的是"不读取聊天内容" | 见"文档修改" | D-009、D-011 |

## 接口与契约映射

### 配置字段

```json
{
  "maskMode": "precise",
  "whitelist": ["文件传输助手", "滴答清单"],
  "preciseListColumn": { "leftInset": 60, "topInset": 0, "width": 242 }
}
```

- 三个字段都可以缺失：`maskMode` 缺失或取值未知时为 `full`；`whitelist` 缺失时为空；`preciseListColumn` 缺失时按 D-007 推导，直到用户在精准遮挡下完成校准才写入。
- `whitelist` 保存前用 `ChatWhitelist.normalized` 整理。
- 编码时总是写出 `maskMode` 和 `whitelist`；`preciseListColumn` 为 `nil` 时不写出。与"写入全部非空字段"的现有规则一致。

### 名称匹配（`ChatNameMatcher`，D-002）

- `normalize(_ s: String) -> String`：
  1. 做 NFC 规范化（`precomposedStringWithCanonicalMapping`）。
  2. 删除表情相关的 Unicode 标量：`properties.isEmojiPresentation` 为真的；`properties.isEmoji` 为真且码位大于 U+00FF 的；U+200D、U+FE0E、U+FE0F、U+20E3，以及 U+1F3FB～U+1F3FF。ASCII 数字、`#`、`*` 保留。
  3. 去掉首尾空白。
- `isWhitelisted(_ recognized: String, whitelist: [String]) -> Bool`：
  1. 规范化识别结果 `r` 和每个名单项 `w`，名单项规范化后为空的忽略。
  2. `r == w` 即匹配。
  3. `r` 以省略号结尾时，去掉省略号并去掉尾部空白得到前缀 `p`。`p` 至少 2 个字符，且某个 `w` 以 `p` 开头，才算匹配。长度下限只会减少露出，用来挡住 OCR 读出的零碎文字。
  4. 省略号的判定（D-013）：末尾连续的 `.`、`…`（U+2026）、`⋯`（U+22EF）、`•`（U+2022）、`·`（U+00B7）都算，不论几个。列表里画的是"…"，但 Vision 会把它读成 `...`、`..`、`.`、`⋯` 等写法（research V-04），只认 `…` 和 `...` 时命中约 35%。代价是名称本身以句点结尾的聊天也会被当成截断。
- 行中的名称文字先由 `ListRowParser` 去掉末尾的时间，再交给匹配。

### 行切分（`ListRowParser`，D-001）

输入是列表栏坐标下的 `[TextBox]`（`text` 与 `rect`，左上角为原点，单位 pt）和列表栏宽度；输出是 `[ListRow]`（`name` 与 `band`）。参数都定义为常量，初值如下：

1. 找正文左边界：统计所有文字框的 `minX`，被最多框共享的值（容差 4 pt）作为正文左边界 `L`，名称和预览都从这里开始。`minX` 与 `L` 相差超过 4 pt 的框不参与切分，比如右侧的时间、头像上的角标。
2. 分行：左对齐的框按 `minY` 排序，取框高的中位数 `h`。相邻两个框的 `minY` 差大于 `1.8 × h` 时，视为新的一行。每组的第一个框是名称行，其余是预览行。
3. 行高：`H` 取相邻行名称框 `minY` 差的中位数。行数少于 3 时，`H = 64 pt`。
4. 带区：先算文字块中心 `c = (名称框.minY + 本组最后一个框.maxY) / 2`，带区为 `[c − H/2 + 2, c + H/2 − 2]`，上下各内缩 2 pt，横向覆盖整个列表栏宽度。
5. 名称：名称框的文字，去掉末尾的时间，匹配的正则为 `\s*(\d{1,2}:\d{2}|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|\d{1,4}[/-]\d{1,2}([/-]\d{1,2})?)$`。

参数先用合成图片测试确定，再用用户本机的真实截图校准（D-010，截图不入库）。

### 变化检测（`ContentFingerprint`，D-003、D-012①）

- 输入：一帧列表栏画面，BGRA，1 倍分辨率（1 像素 = 1 pt），直接在截图队列上计算。
- 计算：
  1. 按 8 pt 高度切成水平条，每条横向平均分成 48 格，每格取平均亮度（`0.299R + 0.587G + 0.114B`）。
  2. 每条取 48 格亮度的中位数作为这一条的底色。
  3. 某格亮度与底色相差超过 24（0～255），记为 1，否则记为 0。这样每条得到 48 位。
- 比较：条数不同，或任意一条的位差（汉明距离）大于 3，就算内容变化。
- 为什么对悬停不敏感：悬停让整行底色一起小幅变化。每一格都是贯穿整条高度的竖切片，所以即使行的边界落在某一条中间，这一条里纯底色的格变化也相同，中位数跟着变，位图不变。实测底色亮度相差 10～12 时，每条只有 0～1 格不同（research V-03）。
- 选中会被当成变化（D-014）：微信 4.1 深色模式的选中行是绿色 `#2EAA6A`，与普通行亮度相差约 70。文字、头像与底色的对比度随之大幅改变，每条有 4～25 格不同。结果是点击白名单行后，已露出的行被盖住，识别完成后再露出；点击本身在遮罩反应之前已经落到微信，照常生效。
- 开销：以列表栏 240 × 800 pt 计，每帧约 100 条 × 48 格，10 帧/秒时可以忽略。

### 截图（`ListCapture`）

> **待定（Q-014）**：下面是最初的方案，实施时发现两处可能不成立，需要先在用户本机探测再定：
> - Apple 文档写明，截取单个窗口时系统不使用 `sourceRect`，总是给整个窗口；macOS 26.5 SDK 头文件的措辞又像是支持。
> - 有报告称对单个窗口持续截图、或用 `SCScreenshotManager` 取静帧时，系统会在该窗口标题栏显示紫色的"正在共享"标记。
>
> 备选：整窗截图后在内存中裁剪；或按显示器截图并用 `sourceRect` 裁剪（窗口移动时要同步更新裁剪区域）。探测脚本见 tasks 4.1a，结果出来后改写本节。

- 内容：用 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` 找到 `windowID` 等于主窗口编号的 `SCWindow`，再用 `SCContentFilter(desktopIndependentWindow:)` 只截这一个窗口。截图里不会有我们自己的遮罩，被别的窗口挡住的部分也能截到。
- 流配置（`SCStreamConfiguration`）：
  - `sourceRect` = 列表栏在窗口内的矩形减去底部遮挡条；`width` 和 `height` 取它的点数，即 1 倍分辨率。
  - `minimumFrameInterval` = 1/10 秒；`pixelFormat` = BGRA；`showsCursor = false`。
  - 只处理 `SCFrameStatus.complete` 的帧。
- 静帧（交给识别用）：`SCScreenshotManager.captureImage(contentFilter:configuration:)`，同样的 `sourceRect`，尺寸取窗口所在屏幕的原生像素（`backingScaleFactor` 倍）。
- 更新：主窗口编号变化时调用 `updateContentFilter`；列表栏矩形变化时调用 `updateConfiguration`。
- 线程：流的输出在专用串行队列上处理，指纹也在这个队列上算；只把"变化"事件切回主线程。

### 先遮后露（`PreciseRevealState` 与 `PreciseRevealController`）

- `PreciseRevealState`（Core）：
  - `contentChanged()`：清空 `revealedBands`，`generation += 1`。
  - `beginRecognition() -> Int`：返回当前的 `generation`。
  - `finishRecognition(generation:bands:)`：只有编号等于当前 `generation` 时才写入 `revealedBands`，否则丢弃。
  - `reset()`：清空，并让之前发出的编号全部失效。
- `PreciseRevealController`（主线程）：
  - 收到变化事件后调用 `contentChanged()`，并重新开始 150 ms 的稳定计时。计时到了就取编号、截静帧、在后台任务中识别，完成后回到主线程提交结果。
  - 识别超过 2 秒未完成时，丢弃结果并在 1 秒后重试。重试前如果又发生变化，按新变化处理。
  - 用全局监听（`NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)`）捕获滚轮：光标在列表栏内时立即调用 `contentChanged()`。被遮住区域上的滚轮事件会被遮罩吃掉，传不到微信，所以只有落在露出行上的滚轮会被看到。
  - 快照里窗口大小变了，或列表栏矩形变了，调用 `contentChanged()` 并更新截图配置（D-012③）。
- 时间上限（D-012②）：内容变化后，下一帧（≤ 0.1 秒）就能发现，再加上切回主线程和重绘，满足"0.3 秒内盖住"。
- Q-011 预留：指纹是按水平条计算的，以后可以改成只让和变化条相交的露出带区失效。这不改变接口；本变更不实现。

### 遮罩规划（`MaskPlanner`，D-006）

- `plan(windowFrame:layout:occluders:revealed:reservedBottomHeight:)`：
  1. `maskRect` 的计算同现在。
  2. 可露出区域 `usable = maskRect` 去掉底部 `reservedBottomHeight` 高的一条。
  3. 露出洞 = 各带区与 `usable` 的交集，向外取整后再裁回 `usable`。
  4. 洞 = 遮挡窗口洞 ∪ 露出洞。
- `reservedBottomHeight`：精准遮挡为 56 pt，整块遮挡为 0。
- `decide` 透传这两个参数；显示与收起规则不变。

### 菜单与状态文字

- "遮挡方式"分组（`NSMenuItem.sectionHeader(title:)`，macOS 14+）：
  - "整块遮挡"（单选）
  - "精准遮挡（只露出白名单）"（单选）
  - "编辑白名单…"：精准遮挡且解锁时才可用
- 精准遮挡且没有屏幕录制权限时：状态行为"精准遮挡需要屏幕录制权限"，并显示菜单项"授予屏幕录制权限…"，点击后调用 `request()` 并打开系统设置。
- 锁定且为精准遮挡、权限正常时：状态行为"已锁定 · 精准遮挡"。其余状态文字不变。
- 锁定时的提示改为"解锁后才能修改密码、校准和编辑白名单"。

### 名单窗口（`WhitelistEditorController`）

- 标题"编辑白名单"。说明文字："每行填一个聊天名称，与聊天列表里显示的一致，有备注就填备注。名称太长被截断也没关系。"
- 内容区是 `TextEditor`，按钮为"取消"和"保存"（默认按钮）。
- 打开时先 `NSApp.activate()`。保存时经 `ChatWhitelist.normalized` 整理后回调；取消或被外部关闭时丢弃修改。
- `AppDelegate` 进入锁定时调用 `close()`（D-012⑤）。

### 屏幕录制权限（`ScreenRecordingPermission`）

- `isGranted`：调用 `CGPreflightScreenCaptureAccess()`。
- `request()`：调用 `CGRequestScreenCaptureAccess()`，首次调用会弹出系统授权提示。
- `openSystemSettings()`：打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`。
- 授权后系统可能要求重启应用（系统弹窗提供"退出并重新打开"），不需要额外处理。缺少权限期间，`PreciseRevealController` 每 5 秒重新检查一次，条件满足时自动开始截图。

### 文档修改

- `docs/architecture.md`：
  - 摘要和 §1 的 v1 范围去掉快捷入口。
  - §5 删除 QuickEntry 行，新增 Capture、Detection 行。
  - 删除 §6.6，新增"精准遮挡"一节（规则同三份规格）。
  - §7 补充三个配置字段；§8 补充屏幕录制权限。
  - §9 删除 M3，v2 行改为"识别失败时保持遮住，需要时输入密码解锁"。
  - §10 删除 M3 的待验证项，补充本设计中的待验证事项。
- `README.md`：
  - 功能列表加上"精准遮挡"。
  - "工作方式与隐私"改为：整块遮挡只需要辅助功能权限；精准遮挡还需要屏幕录制权限，会读取聊天列表区域的画面，在本机识别名称，不保存、不上传。
  - "下载安装"补充：升级后屏幕录制权限也需要重新授权。
  - 后续计划删除快捷入口和精准遮挡。

## 状态与交互行为

### 加载、空、成功与错误状态

| 遮挡方式 | 条件 | 遮罩表现 | 是否截图 |
| --- | --- | --- | --- |
| 整块遮挡 | 锁定且微信窗口可见 | 与现在相同 | 否 |
| 精准遮挡 | 解锁 | 收起（与现在相同） | 否 |
| 精准遮挡 | 锁定，名单为空 | 整块遮住，密码框在底部条中 | 否 |
| 精准遮挡 | 锁定，没有权限，或截图失败 | 整块遮住，菜单显示提示和授权入口 | 否，每 5 秒检查权限 |
| 精准遮挡 | 锁定，截图正常，识别尚未完成或刚发生变化 | 整块遮住（先遮） | 是 |
| 精准遮挡 | 锁定，识别完成 | 只露出匹配的行，底部条始终遮住 | 是 |
| 精准遮挡 | 校准中（需要先解锁） | 半透明校准框，不开露出洞 | 否（已解锁） |

截图失败（`stream(_:didStopWithError:)`、找不到 `SCWindow`、静帧失败）时，调用 `reset()`，按"没有权限或截图失败"处理，5 秒后重试。日志只记录错误码和次数。

### 权限与校验

- 切换遮挡方式：锁定时也可以（D-005）。
- 编辑白名单：精准遮挡且解锁时才可以（D-005、D-012⑥）。
- 在精准遮挡下校准：沿用现有规则，需要先解锁。完成后写入 `preciseListColumn`；整块遮挡下写入 `listColumn`（D-007）。
- 切换到精准遮挡时：没有权限就调用 `request()`（masking-mode 规格）；名单为空且已解锁就打开名单窗口（chat-whitelist 规格）。
- 日志：只记录帧数、变化次数、识别耗时、匹配行数；识别出的文字一律不写入日志（D-011）。

## 决策与替代方案

- **截图接口**：选 ScreenCaptureKit 的单窗口流，不用 `CGWindowListCreateImage`。后者在 macOS 14 起已弃用，而且截到的是屏幕上的样子，会把遮罩也截进去。
- **变化检测**：选去底色指纹，不用整帧哈希。整帧哈希会把悬停当成变化，白名单行就点不了了（D-012①）。
- **行切分**：按间距几何切分，不用验证脚本里的亮度阈值。亮度阈值只在深色模式下成立。
- **识别代码的位置**：放在本地包的新 target 里，不放在应用外壳，这样 `swift test` 能用合成图片覆盖完整的识别流程；Core 保持不依赖系统框架。
- **名单编辑方式**：用每行一个名称的文本框，不做可增删的表格。文本框方便粘贴，代码也少。

## 兼容、迁移与回滚

- 配置新增的字段都可以缺失，旧配置读出来就是整块遮挡，不需要迁移。
- 回滚到旧版本时，旧版本会忽略未知字段（现有兼容规则），自动回到整块遮挡；精准遮挡相关的字段保留在文件中，不影响旧版本。
- 整块遮挡时 `revealed = []`、`reservedBottomHeight = 0`，`MaskPlanner` 的结果与现在一致，由现有单测保证。

## 风险与缓解措施

| 风险 | 缓解措施 |
| --- | --- |
| 真实画面下名称识别错误，或行切分不准 | 识别不出就保持遮住；`customWords` 填入名单；参数集中定义，先用合成图片测试，再用本机真实截图校准（D-010） |
| 浅色模式、悬停下指纹或切分失效 | 两种算法都不依赖具体颜色；合成图片覆盖浅色和悬停；探测脚本记录真实悬停画面下指纹的差异（tasks 4.1a）；本机验收时逐项核对 |
| 选中后已露出的行闪一下（D-014） | 已接受；点击照常生效。以后可以和 Q-011 一起优化 |
| 截图方案不成立（Q-014） | 先探测再实现；探测结果出来前不写截图代码 |
| macOS 定期要求重新确认屏幕录制权限（macOS 26 上的行为待确认） | 按 D-008 退化为整块遮住，菜单提供入口；验收时记录实际表现 |
| 临时签名的发布包升级后要重新授权 | README 说明 |
| CPU 和耗电 | 只在满足条件时截图；画面静止时系统不推送帧；指纹用 1 倍分辨率；只在画面稳定后才识别 |
| Q-011 未采纳时，已露出的行会随新消息闪动 | 记为 Non-blocking 事项；实现上保留按水平条让带区失效的余地 |
| OCR 增删名称中间的空格，导致完全一致匹配失败 | 失败时保持遮住（安全）；若本机验证发现这个问题，另行提议放宽规则，需用户确认 |

## 测试策略

- Core 单测（`swift test --package-path macos/QuietChatCore`）：
  - `AppConfig`：新字段的默认值、缺失和未知取值、`listColumnLayout(for:)` 的推导（D-007）；schema 一致性测试加入新字段。
  - `ChatWhitelist.normalized`：首尾空白、空行、去重、保持顺序。
  - `ChatNameMatcher`：完全一致、只包含不算、表情、省略号的各种写法（D-013）、前缀不足 2 个字符、重名。
  - `ListRowParser`：有预览和无预览的行、右侧时间框、角标、少于 3 行时回退、名称末尾的时间被去掉。
  - `ContentFingerprint`：合成帧中整行底色变化（悬停）不算变化；文字变化、整体平移算变化。
  - `PreciseRevealState`：变化即清空、过期结果丢弃、`reset()` 后旧编号失效。
  - `MaskPlanner`：默认参数下结果与现在一致；露出带区被裁剪、底部条不开洞、与遮挡洞合并。
- `QuietChatDetection` 单测：用 CoreText 生成合成列表图片（深色、浅色、一行悬停、一个截断名称），跑 `TextRecognizer` → `ListRowParser` → `ChatNameMatcher`。断言白名单行全部找到、带区与真实行的交并比大于 0.8，非白名单行不匹配。
- 构建：`xcodebuild` 的 Debug 和 Release 都通过，没有警告；启动冒烟：新实例能起来，没有新的崩溃报告。
- 本机验收（用户）：按三份规格的场景逐条核对；同时查看日志，确认没有聊天名称。
- 回归：整块遮挡模式下重新核对 M1、M2 的验收清单。

## 未解决的事项

- **Blocking** Q-014：截图方案，见"截图"一节。探测结果出来前，`ListCapture`、`PreciseRevealController` 及依赖它们的装配不实现。
- Q-011：只让内容变化的露出行失效，减少闪动。需要用户决定；未采纳前按 D-003 实现。
- 没有消息预览的行，名称不上下居中而是靠上（research V-03），按"文字块中心"算出的带区会偏上约 7 pt。露出的是上一行底部的空白，不含文字；用真实截图校准时一并处理。
- 行切分和指纹的参数初值，需要用本机真实截图校准（D-010）。
- macOS 26 上屏幕录制"定期重新确认"的实际表现，在验收时记录。
