// 应用配置模型与读写。
// 字段与 shared/config.schema.json 一一对应，macOS 与 Windows 读写同一格式（测试会校验两者一致）。
// 兼容规则：缺失字段取默认值、未知字段忽略，因此新旧版本可以读取彼此写出的配置。

import Foundation

/// QuietChat 的持久化配置。
public struct AppConfig: Codable, Equatable, Sendable {
    /// 当前配置格式版本；只有不兼容的格式变化才递增。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// 聊天列表栏的位置（校准结果）。
    public var listColumn: ListColumnLayout

    public init(schemaVersion: Int = Self.currentSchemaVersion, listColumn: ListColumnLayout = .default) {
        self.schemaVersion = schemaVersion
        self.listColumn = listColumn
    }

    public static let `default` = AppConfig()

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        listColumn = try container.decodeIfPresent(ListColumnLayout.self, forKey: .listColumn) ?? .default
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
