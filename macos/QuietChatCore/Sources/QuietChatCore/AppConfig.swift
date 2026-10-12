// 应用配置模型与读写。
// 字段与 shared/config.schema.json 一一对应，macOS 与 Windows 读写同一格式（测试会校验两者一致）。
// 兼容规则：缺失字段取默认值、未知字段忽略，因此新旧版本可以读取彼此写出的配置。

import Foundation

/** 锁定时的遮挡方式；两种方式共用解锁和自动锁定规则。 */
public enum MaskMode: String, Codable, Sendable {
    /// 整块遮住聊天列表栏。
    case full
    /** 不透明遮罩上的静态白名单快捷入口。 */
    case shortcuts

    /** 旧 precise 映射到快捷入口；未知字符串回退整块遮挡，编码只输出当前方式。 */
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "precise" ? .shortcuts : Self(rawValue: value) ?? .full
    }
}

/** 应用的外观偏好；跟随系统时由平台实时决定浅色或深色。 */
public enum AppearanceMode: String, Codable, Sendable {
    /** 跟随系统外观。 */
    case system
    /** 固定使用浅色外观。 */
    case light
    /** 固定使用深色外观。 */
    case dark

    /** 读取外观偏好；未知字符串回退到跟随系统，兼容更新版本的配置。 */
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
    }
}

/// QuietChat 的持久化配置。
public struct AppConfig: Codable, Equatable, Sendable {
    /// 当前配置格式版本；只有不兼容的格式变化才递增。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// 整块遮挡下聊天列表栏的位置（校准结果）。
    public var listColumn: ListColumnLayout
    /// 遮挡方式；默认整块遮挡。
    public var maskMode: MaskMode
    /** 快捷入口的完整搜索名称，保存前由 `ChatWhitelist.normalized` 整理。 */
    public var whitelist: [String]
    /** 快捷入口方式的独立校准；保留历史键名，nil 时由整块遮挡布局推导。 */
    public var preciseListColumn: ListColumnLayout?
    /// 用户设置的解锁密码；nil 表示从未修改或已恢复默认，使用默认密码。
    public var password: PasswordRecord?
    /// 遮罩上的密码框是否隐藏输入内容；默认明文显示，记住用户最后一次的选择。
    public var hidePasswordInput: Bool
    /** 整个应用的外观偏好；默认跟随系统，重启后沿用最后保存的选择。 */
    public var appearanceMode: AppearanceMode

    public init(
        schemaVersion: Int = Self.currentSchemaVersion, listColumn: ListColumnLayout = .default,
        maskMode: MaskMode = .full, whitelist: [String] = [], preciseListColumn: ListColumnLayout? = nil,
        password: PasswordRecord? = nil, hidePasswordInput: Bool = false, appearanceMode: AppearanceMode = .system
    ) {
        self.schemaVersion = schemaVersion
        self.listColumn = listColumn
        self.maskMode = maskMode
        self.whitelist = whitelist
        self.preciseListColumn = preciseListColumn
        self.password = password
        self.hidePasswordInput = hidePasswordInput
        self.appearanceMode = appearanceMode
    }

    public static let `default` = AppConfig()

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        listColumn = try container.decodeIfPresent(ListColumnLayout.self, forKey: .listColumn) ?? .default
        maskMode = try container.decodeIfPresent(MaskMode.self, forKey: .maskMode) ?? .full
        whitelist = try container.decodeIfPresent([String].self, forKey: .whitelist) ?? []
        preciseListColumn = try container.decodeIfPresent(ListColumnLayout.self, forKey: .preciseListColumn)
        password = try container.decodeIfPresent(PasswordRecord.self, forKey: .password)
        hidePasswordInput = try container.decodeIfPresent(Bool.self, forKey: .hidePasswordInput) ?? false
        appearanceMode = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
    }

    /** 指定方式的布局；快捷入口未校准时沿用整块遮挡左右边界，上边距取 0 以遮住整个列表。 */
    public func listColumnLayout(for mode: MaskMode) -> ListColumnLayout {
        switch mode {
        case .full:
            listColumn
        case .shortcuts:
            preciseListColumn ?? ListColumnLayout(leftInset: listColumn.leftInset, topInset: 0, width: listColumn.width)
        }
    }
}

/// 配置文件的读写。
public struct ConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// macOS 上的默认位置：`~/Library/Application Support/QuietChat/config.json`。
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(components: "QuietChat", "config.json")
    }

    /// 读取配置。文件不存在时返回默认配置；文件损坏时抛错，由调用方决定是否退回默认配置。
    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .default }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fileURL))
    }

    /// 写入配置：自动创建目录并原子写入；按键排序、缩进输出，方便手工查看和比对。
    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
