# OpenSpec 归档记录

## 审阅摘要

2026-10-15 按用户要求归档全部 6 个活动变更。归档保留原始文件和任务勾选状态；现行能力汇总至 `../../specs/`，已被替代的方案仅保留历史，不合入现行规格。归档不代表未完成任务已经通过验收。

## 归档清单

| 变更 | 处理 | 原任务状态 |
| --- | --- | --- |
| [add-precise-masking-mode](2026-10-15-add-precise-masking-mode/) | 被白名单快捷入口替代，仅归档历史 | 20/27 |
| [replace-precise-masking-with-whitelist-shortcuts](2026-10-15-replace-precise-masking-with-whitelist-shortcuts/) | 同步 masking-mode、chat-whitelist、whitelist-shortcuts | 27/27 |
| [add-shortcut-timing-controls](2026-10-15-add-shortcut-timing-controls/) | 被常规响应速度设置替代，仅归档历史 | 8/8 |
| [promote-whitelist-shortcut-timing](2026-10-15-promote-whitelist-shortcut-timing/) | 同步 shortcut-timing-controls | 6/6 |
| [add-macos-auto-update](2026-10-15-add-macos-auto-update/) | 同步 macos-app-update、signed-macos-release | 9/11 |
| [add-timed-strong-control](2026-10-15-add-timed-strong-control/) | 同步 timed-strong-control | 8/8 |

## 未完成事项与验证边界

- 旧精准遮挡方案的 7 项未完成任务随替代方案退役，不补记完成，不再按旧方案实施。
- 自动更新的 [tasks.md](2026-10-15-add-macos-auto-update/tasks.md) 中 4.1、4.2 仍未完成：维护者配置 GitHub Secret `SPARKLE_ED25519_PRIVATE_KEY`；Intel/macOS 14 真机、系统重新授权和管理员批准界面验证。正式发布前仍需处理。
- 现行规格通过 `openspec validate --all --strict --no-interactive` 校验；历史任务状态另见原始 tasks.md，不能用结构校验代替实际验收。
