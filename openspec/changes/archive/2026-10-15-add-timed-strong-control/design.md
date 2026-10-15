# 技术设计

## 审阅摘要

- 方案：Core 配置与运行期状态分离，使用 `ContinuousClock`，AppDelegate 统一路由解锁及设置修改。
- 边界：原生菜单与遮罩，专用手输编辑器复用于提前修改确认；保持现有自动锁定及快捷取消规则。
- 兼容：schemaVersion 1；旧配置默认关闭/30 分钟，新增字段独立回退，截止时间不编码。
- 验证：可注入时刻的 Core 测试、真实 AppKit 控件/菜单检查、Debug 构建及严格规格校验。
- 风险：到期竞态、共享 field editor 污染与控件挤压；通过要求快照、专用编辑器与动态底部高度控制。无待确认项。

## 当前与目标流程

[CODE] AppDelegate.attemptUnlock 当前直接调用 PasswordVerifier，MaskController 将 Bool 结果转为错误提示，MaskView 使用明文/安全框。目标输入携带 `UnlockRequirement`；AppDelegate 重新取得当前要求，不一致时只刷新并清空，不能按新要求验证旧草稿。

加载 AppConfig → 恢复开关和分钟数、创建空 TimedControlState → 等待正常密码成功 → 在当前 ContinuousClock.Instant 上设截止时间 → 重锁后改为 Q-M 输入 → 到期清除运行期周期并恢复普通输入。原密码成功开启下一轮，Q-M 成功不改变截止时间。

## 修改地图与接口

| 区域 | 路径与符号 | 实施契约 |
| --- | --- | --- |
| Core | `QuietChatCore` 新增 TimedControlSettings / TimedControlState / UnlockRequirement，扩展 AppConfig | settings 为 Codable/Equatable/Sendable，只保存 enabled 与 durationMinutes；状态提供当前要求、剩余秒、成功解锁及设置应用，均接受显式时刻；只保存内存截止时间 |
| 装配 | `AppDelegate`：attemptUnlock、applyMaskMode、菜单 delegate | 根据提交快照路由原密码/Q-M；活动期间 Timer 每秒刷新，使用 common run loop mode；保存设置成功后才应用周期变化 |
| 输入与布局 | `MaskView`、`MaskController`、新增强控控件与确认对话框 | 第三个专用明文输入框，要求改变时清空并释放焦点；普通显示偏好不被覆盖；底部高度及快捷区域根据提示控件实际高度调整 |
| 菜单与配置 | `StatusMenuController`、`shared/config.schema.json` | 新子菜单含开关、状态、预设和自定义；配置版本不变，保存更新整组设置且保留其他字段 |

`UnlockRequirement` 区分 `.password` 与 `.keyboardSequence` 并提供唯一固定字符串。输入提交返回成功、失败或要求已变更，后者不显示“密码错误”。强控只完整比较小写，不 trim、不保存到 password 字段。

## 状态与交互契约

- 当前时刻小于截止时间才活动；相等即到期。剩余秒向上取整，按分秒展示。ContinuousClock 包含睡眠且不受系统时间修改影响。
- 设置未变时无操作。未活动时修改只保存偏好；活动时关闭/修改需 Q-M。自定义先取得合法数值，再确认；取消任一步均不改变状态。
- 提前修改确认使用独立的明文手输控件，回车确认；仅对当前设置动作授权，不调用解锁函数。确认期间到期后再次读取实际时刻，不重启已经结束的周期。
- 保存按“复制 AppConfig → 原子写入 → 应用设置与周期”执行；失败弹窗反馈且保留旧值，时间自然流逝不视为修改。成功保存的时刻作为新周期起点。
- 专用 NSTextFieldCell 返回独立 NSTextView field editor；拦截粘贴及 pasteboard/drag 导入、禁用自动文本替换，限制逐键插入；普通密码控件继续使用原编辑器。两种输入均保留首次点击取焦点行为。
- 强控区增加剩余时间和完整序列，序列按需要换行而不截断；底部空间与快捷按钮区域同步调整。透明洞覆盖控件时整体隐藏，继续让出上层窗口点击。
- 计时刷新不取消搜索、改变校准或锁定；主动菜单操作仍按原规则取消未完成搜索。退出 QuietChat 释放 Timer 和监听。

## 兼容与验证

旧配置字段缺失或整个新增对象非法采用默认设置；对象内 enabled 类型错误回退 false、分钟数缺失/类型错误/越界回退 30，其他有效字段保留。正常保存包含新对象，不包含活动截止时间；旧程序忽略新增字段。

Core 测试使用固定起始 instant 与显式推进，覆盖固定周期、失败、边界、修改、关闭和重建状态；配置与 Schema 验证新增字段、回退和不写文件。AppKit 检查实际输入控件及菜单，验证编辑、粘贴、拖入、自动替换、显示偏好、空间/遮洞及输入快照；替身/临时配置避免改写真实用户配置或发送微信按键。最后运行 Core、禁用自动解析的 Debug 构建及严格 OpenSpec 校验。无新增依赖与权限，无待解决事项。
