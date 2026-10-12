# 技术设计

## 审阅摘要

- 方案：菜单阶段预设加整数输入，使用不可变 Core 值类型保存，点击搜索时捕获快照。
- 边界：复用 AppKit 菜单、现有配置原子保存及焦点取消；搜索按键和等待核对不变。
- 兼容：新字段默认 150／50／500，单段错误独立回退，旧字段保留，版本仍为 1。
- 验证：配置及 Schema 测试、实际菜单动作检查、Debug 构建与签名；真实微信测试由用户执行。
- 风险：试验值会持久化，零等待不等于零总耗时；提供明确测试标签和一键恢复。

## 当前与目标流程

[CODE] 现有菜单每次打开重建并取消未结束搜索；AppDelegate.openShortcut 传入名单与目标；execute 使用三处常量等待。

目标选择流程：菜单预设／自定义 → 完整 ShortcutTiming → AppDelegate 取消旧操作 → 更新 config.shortcutTiming → ConfigStore.save。

目标搜索流程：白名单点击 → start 接收整组值 → Task 捕获不可变值 → 聚焦与原键盘序列 → 按快照等待 → 普通回车／人工交接。配置变化不重放事件。

## 修改地图

| 区域 | 路径与符号 | 变更 |
| --- | --- | --- |
| Core | ShortcutTiming.swift、AppConfig.swift | 不可变 Codable 值、边界与独立回退、新配置字段 |
| 菜单 | StatusMenuController.swift：StatusMenuDelegate、menuNeedsUpdate | 参数状态与选择接口、三个阶段子菜单及自定义对话框 |
| 装配 | AppDelegate.swift：openShortcut、StatusMenuDelegate 实现 | 注入快照、取消及保存；沿用保存失败策略 |
| 搜索 | WeChatShortcutController.swift：start、execute | 快照代替三处常量、开始记录参数，原 wait 不变 |
| 契约与说明 | shared/config.schema.json、Core 测试、README、docs/architecture.md | 字段一致性、人工测试方法及当前参数边界 |

## 接口与数据契约

- public ShortcutTiming 为 Codable、Equatable、Sendable；三个 Int 属性只读，基准为 150／50／500，计算属性 totalMs 不编码。
- 初始化与解码按阶段验证 0...基准；缺失、类型错误、小数或越界值回退该阶段基准。顶层 shortcutTiming 无效时回退整组，不连带重置其他配置。
- AppConfig.shortcutTiming 非可选，默认基准，保存时编码三个字段；共享 Schema 声明整数、最小 0、相应最大值及默认值。
- StatusMenuDelegate 提供 shortcutTiming 与 selectShortcutTiming；AppDelegate 再核对 shortcuts 方式，相同值不重复保存。
- start 显式接收 timing，execute 仅使用捕获值；操作开始日志记录三个整数，不携带用户内容。

## 菜单与交互

- 父菜单位于编辑白名单之后；显示当前总和、三个阶段子菜单与恢复基准，父菜单在 full 时禁用。
- 阶段预设固定为规格表；菜单内部阶段标识关联 action，改变一个值时以当前整组构造新值。自定义不在预设内时勾选自定义项并显示毫秒值。
- 自定义使用原生 NSAlert 和 NSTextField，预填当前值，保存／取消两按钮；去除首尾空白后解析 Int 并核对范围。错误原框重试，不先写配置；取消不恢复已取消搜索。
- 锁定时也可调整，菜单／对话框不解锁。打开菜单已有取消路径，选择处理再取消以覆盖其他调用方。
- 保存失败与外观偏好一致：本次仍生效、错误写日志；不自动回滚、重试或启动搜索。

## 兼容与回滚

新配置版本保持 1。旧配置无时序对象时默认基准，旧程序忽略新字段；读取不自动重写。恢复基准只替换时序，不触碰名单、密码或校准。历史 OpenSpec 的原门禁数值保留，新菜单是用户明确授权的试验配置范围。

## 验证与实测

纯逻辑测试覆盖有效值、零、自定义值、部分缺失、错误类型、小数、越界、对象无效、往返、旧配置和共享 Schema；测试使用临时配置，不改用户文件。

菜单检查覆盖位置、锁定可用、full 禁用、当前勾选、单段修改、恢复与对话框校验；使用替身 delegate，不发送微信事件。构建禁用自动依赖解析并输出至临时 DerivedData。

人工测试按等待结果、打开搜索、全选旧词顺序，每候选至少 5 次；用整数中点细分至间隔不超过 1 毫秒，零通过时作为候选下限。最终组合至少 20 次并覆盖旧词、密码焦点、文件传输助手及中途取消。误输入或错误提交时记录参数并恢复基准。二分不假定响应严格单调，真实微信场景不由工具自动执行。
