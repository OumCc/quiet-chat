# 调研记录

## 审阅摘要

- 缘由：[USER] 用户已实测三段零等待可用，要求将速度试验转为常规功能。
- 目标：[USER] 菜单改名、默认全零、精简预设，并提供效果不佳时的调整说明。
- 已确认：[USER] 升级时全部重置速度设置；自定义范围保留；合计与恢复基准保留。用户已明确批准本方案实施。
- 边界：只调整速度菜单、配置兼容及说明，沿用搜索、焦点、取消与保存行为。
- 验收：Core、迁移与 Schema 测试，替身菜单检查，Debug 构建及 OpenSpec 严格校验。
- 风险：全零效果依赖微信响应，保留 75／25／250 及原范围自定义；旧设置按明确授权重置。
- 待确认：无 Blocking 问题；真实微信效果以用户实测为依据，不冒记自动验收。

## 输入清单

| ID | 来源 | 格式与日期 | 位置 | 状态 |
| --- | --- | --- | --- | --- |
| S-01 | [USER] 常规功能要求及全零实测反馈 | 中文 Markdown，2026-10-12 | 本次对话原始需求 | 已接收 |
| S-02 | [USER] 三项澄清及完整方案实施授权 | 选项回复与 Markdown，2026-10-12 | Q-001～Q-003、PLEASE IMPLEMENT THIS PLAN | 已确认 |
| S-03 | [CODE] 当前实现及配置契约 | Swift、JSON、Markdown | 下方当前实现表 | 已核对 |
| S-04 | [CODE] 历史时序变更 | OpenSpec Markdown | `../add-shortcut-timing-controls/` | 作为历史证据保留 |

## 需求理解与验收

[USER] 菜单入口为「白名单快捷入口响应速度」。三个阶段分别为「打开搜索」「全选旧搜索词」「等待搜到结果」，每段只显示零基准、75／25／250 中对应的非零预设及自定义。合计与恢复基准保留，恢复后总和为零。

[USER] 只有 shortcuts 方式可调整；锁定时仍可用。升级时清除所有旧速度选择，此后用户选择保存并重启沿用。自定义范围仍为 0～150／0～50／0～500 毫秒。

[USER] README 说明该功能控制固定等待；效果不佳时尝试非零组合或自定义，固定等待合计不代表真实打开聊天的耗时。

验收必须区分旧配置统一归零与带当前标记配置的独立字段回退。菜单检查使用替身，不向微信发送事件；不新增搜索判定、自动重试、权限或依赖。

## 视觉证据

没有新增原型或必需图片；[USER] 要求沿用当前原生菜单与对话框结构。

## 当前实现

| 证据 | 路径与符号 | 当前行为与影响 |
| --- | --- | --- |
| [CODE] | `macos/QuietChat/App/StatusMenuController.swift`：`TimingStage`、`makeShortcutTimingItem` | 上限从 `.baseline` 取值，预设按上限递减生成；需将上限、基准和预设拆开 |
| [CODE] | `macos/QuietChatCore/Sources/QuietChatCore/ShortcutTiming.swift`：初始化与解码 | 默认、无效回退及上限均为 150／50／500；需改默认与回退，保留上限 |
| [CODE] | `macos/QuietChatCore/Sources/QuietChatCore/AppConfig.swift`：`init(from:)`、`ConfigStore` | 有效旧时序原样保留，读取不写文件，保存原子写入；需要版本标记区分迁移前后 |
| [CODE] | `macos/QuietChat/App/AppDelegate.swift`：`selectShortcutTiming` | 再核对 shortcuts、取消旧操作并保存，沿用相同值不重复保存及失败本次生效 |
| [CODE] | `macos/QuietChat/Shortcuts/WeChatShortcutController.swift`：`start`、`wait` | 按不可变快照使用三个等待；零值也执行权限、焦点与取消核对 |
| [CODE] | `shared/config.schema.json` 与 `AppConfigTests.encodedFieldsMatchSharedSchema` | 配置字段严格对齐，默认与最大值测试目前绑定，需分别检查 |
| [CODE] | `README.md`、`docs/architecture.md` | 当前描述为测试菜单、700 毫秒基准及人工二分；需更新当前行为 |

## 契约映射与变更影响

| 动作或输入 | 状态与结果 | 依据 |
| --- | --- | --- |
| 阶段选择或有效自定义 | 仅替换对应阶段，保存完整时序；下次点击使用快照 | [CODE] `TimingStage.replacing`、`selectShortcutTiming` |
| 恢复基准 | 三段清零，合计归零 | [USER] S-01、Q-003 |
| 旧配置无有效 `shortcutTimingVersion` | 时序整组归零，其他有效字段保留，读取不写文件 | [USER] S-02 已批准方案 |
| 当前标记为 1 | 沿用有效时序，错误字段独立归零；保存带标记 | [USER] S-02 已批准方案 |

接口影响限于追加 `shortcutTimingVersion`，`schemaVersion` 保持 1，三个时序字段名称、类型与上限保留。macOS 工程只引用本地无外部依赖的 Core 包；使用 Swift/Xcode 并禁用自动依赖解析。当前没有 Windows 业务实现，本次不新增。

## 矛盾与问题

| ID | 分类／状态 | 证据或冲突 | 选项与建议 | 决策及影响 |
| --- | --- | --- | --- | --- |
| Q-001 | Blocking／ANSWERED | [CODE] 旧设置持久化；[USER] 要求全零默认但最初未说明升级处理 | 保留值（原建议）／全部重置／仅旧基准重置 | [USER] 全部重置；增加一次性迁移标记 |
| Q-002 | Blocking／ANSWERED | [CODE] 上限绑定基准，全零会使非零输入无效 | 保留原范围（建议）／缩至保留预设 | [USER] 保留原范围；上限独立于基准 |
| Q-003 | Blocking／ANSWERED | [USER] 「其它选项都去掉」与保持交互需明确辅助项 | 保留两项（建议）／只保留合计／两项移除 | [USER] 保留合计与恢复基准 |

## 决策记录与就绪检查

- D-001：[USER] Q-001 及实施授权确认追加 `shortcutTimingVersion: 1`；加载旧值归零，正常保存写标记，后续修改保留。
- D-002：[USER] Q-002 确认自定义上限不缩减；当前标记下原预设值可作为自定义使用。
- D-003：[USER] Q-003 确认保留合计和恢复基准；恢复项文案为「恢复基准（0 毫秒）」。
- D-004：[USER] S-02 已明确批准本方案实施，不再等待重复审批。
- [x] 来源已完整接收，格式、边界与用户决策已记录。
- [x] 当前菜单、配置、搜索及共享契约已检查；没有必需的缺失视觉材料。
- [x] 没有 Blocking 问题处于 OPEN 状态。
- [x] 可创建后续产物并严格校验，校验通过后按已授权方案实施。
