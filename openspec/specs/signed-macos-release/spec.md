# macOS 签名发布规格

## 审阅摘要

- 目标：通过固定 EdDSA 公钥验证 DMG 与 appcast，确保稳定版本资产完整且校验通过后再公开。
- 边界：保留临时应用签名，不将更新私钥写入源码、发布资产或日志。
- 验收与风险：覆盖密钥缺失、版本不符、签名无效及手动构建；维护者仍需配置 GitHub Secret SPARKLE_ED25519_PRIVATE_KEY。

## Purpose

通过固定 EdDSA 公钥验证 DMG 与 appcast，确保稳定版本资产完整且校验通过后再公开。

## Requirements

### Requirement: 更新信任链

系统 MUST 嵌入固定 EdDSA 公钥，要求已签名清单和提取前归档验证，不因等待超时退化为接受未签名清单。私钥不得写入源码、发布资产或日志。

#### Scenario: 私钥与客户端不匹配
- **WHEN** 发布密钥不能生成嵌入公钥可验证的归档
- **THEN** 校验失败，禁止公开 Release

### Requirement: 完整稳定版本发布

系统 SHALL 使用原 v* tag 工作流，要求稳定语义版本与 Version.xcconfig 一致、有效更新密钥。DMG、SHA-256、版本说明和 appcast 全部就绪并验证后，先上传草稿再公开并设为 latest。清单只包含完整 DMG，版本和系统要求来自应用包。

#### Scenario: 正式发布
- **WHEN** 推送匹配版本且配置有效密钥的稳定 tag
- **THEN** 发布完整 Release，latest/download/appcast.xml 引用对应 tag 的固定归档地址

#### Scenario: 密钥缺失或校验失败
- **WHEN** 未提供私钥、tag 不匹配或签名验证失败
- **THEN** 工作流失败，已有 latest 不改变

#### Scenario: 手动构建
- **WHEN** 通过 workflow_dispatch 构建且没有发布密钥
- **THEN** 仍可构建 DMG workflow artifact，不公开 Release
