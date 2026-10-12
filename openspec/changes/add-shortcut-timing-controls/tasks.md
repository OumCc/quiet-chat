# 实施任务

## 审阅摘要

- 目标：实现分阶段预设、自定义及持久化，保持主动点击与原取消机制。
- 顺序：产物校验 → Core 与 Schema → 菜单／装配／快照 → 文档 → 测试与构建。
- 完成定义：代码及可执行测试版交付；真实微信极限与最终组合由用户后续实测，不冒记通过。
- 验证集合：配置聚焦测试与 Core 回归、菜单动作及输入检查、Debug、签名、OpenSpec 严格校验及 diff。

## 1. 契约

- [x] 1.1 完成 research-first 产物及严格校验 — 验证：status 为 5/5，validate --strict --no-interactive 通过。
- [x] 1.2 实现 ShortcutTiming、AppConfig 与共享 Schema — 验证：默认、边界、独立回退、旧配置与字段一致性测试通过。

## 2. 菜单与执行

- [x] 2.1 增加分阶段预设、自定义对话框及恢复基准 — 验证：位置、勾选、锁定可用、full 禁用、输入范围及取消通过菜单检查。
- [x] 2.2 接入参数保存、取消和搜索快照 — 验证：单段更新保留其他值，重载恢复配置；原 wait 与焦点代码保留，参数变更不自行搜索。
- [x] 2.3 添加操作开始参数日志 — 验证：仅含三段整数、阶段、耗时或错误码，不记录名称和搜索内容。

## 3. 交付

- [x] 3.1 同步 README 与架构 — 验证：人工二分方法、保存行为、恢复基准及日志边界与实际实现一致，历史 change 不改写。
- [x] 3.2 完成 Core 回归与 Debug 构建、签名检查 — 验证：既有本地工具链通过，无依赖安装，生成临时测试应用。
- [x] 3.3 更新实际验证记录，完成最终 OpenSpec 与 diff 检查 — 验证：结果真实，手动微信测试明确待用户执行，可运行应用路径已提供。

## 实际验证记录（2026-10-12）

- 实施前产物：research-first 的五份产物落盘后，status 显示 5/5，严格校验通过，再开始业务代码。
- Core：`swift test --package-path macos/QuietChatCore --scratch-path /private/tmp/quiet-chat-timing-core-tests-20261012 --disable-automatic-resolution` 通过 63 项测试、11 个 suite；包括零值、中点、错误类型／小数／越界独立回退、旧配置不重写、有效设置保留、保存重载及共享 Schema。
- 菜单：临时检查程序从实际 StatusMenuController.swift 与已构建 Core 编译，使用替身 delegate，未读写用户配置或发送微信事件。实际 selector 检查通过入口位置、三组完整预设、锁定时可用、full 禁用与调用拒绝、单段修改、总和、预设／自定义唯一勾选、全零及恢复基准。真实 NSAlert 自动检查通过预填、151／-1／1.5／非数字错误提示、56 毫秒中点、首尾空白及取消保留。
- 执行边界：源码与 diff 核对 start 捕获不可变值、execute 使用三段快照；wait、validate、原焦点和键盘选择逻辑未改。日志新增行仅记录三个整数和 started 阶段。值语义快照通过菜单检查；没有把这些检查写成实际微信已打开或运行中取消验收。
- 构建：Debug BUILD SUCCEEDED，禁用自动包解析并输出至 `/private/tmp/quiet-chat-timing-controls-20261012`；开发签名严格校验通过。构建唯一警告是没有 AppIntents.framework 而跳过元数据提取。没有新增依赖、安装或改动本地签名设置。
- 手动待测：真实微信打开时间、零等待可用性、密码框交接、中途取消和最终至少 20 次组合测试由用户后续确认；未自动搜索、修改用户配置或把 finished 当作聊天显示。
- 最终校验：最终源码增量 Debug 构建及严格签名再次通过；OpenSpec status 为 5/5，validate --strict --no-interactive 返回 valid，diff 检查通过。测试应用位于 `/private/tmp/quiet-chat-timing-controls-20261012/Build/Products/Debug/QuietChat.app`。
