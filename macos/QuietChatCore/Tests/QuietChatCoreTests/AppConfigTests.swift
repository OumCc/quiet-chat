import Foundation
import Testing
@testable import QuietChatCore

struct AppConfigTests {
    private func temporaryStore() -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuietChatTests-\(UUID().uuidString)")
        return ConfigStore(fileURL: directory.appending(components: "QuietChat", "config.json"))
    }

    @Test func missingFileLoadsDefaults() throws {
        #expect(try temporaryStore().load() == .default)
    }

    /// 所有字段都有值的配置，用来检查读写和 schema 一致性。
    private let fullConfig = AppConfig(
        listColumn: ListColumnLayout(leftInset: 70, topInset: 12, width: 300),
        maskMode: .precise,
        whitelist: ["文件传输助手", "滴答清单"],
        preciseListColumn: ListColumnLayout(leftInset: 70, topInset: 0, width: 300),
        password: PasswordRecord(iterations: 100_000, salt: "c2FsdA==", hash: "aGFzaA=="),
        hidePasswordInput: true,
        appearanceMode: .dark)

    @Test func savedConfigRoundTrips() throws {
        let store = temporaryStore()
        try store.save(fullConfig)
        #expect(try store.load() == fullConfig)
    }

    @Test func missingFieldsFallBackToDefaultsAndUnknownFieldsAreIgnored() throws {
        let json = #"{"listColumn": {"width": 300}, "fromTheFuture": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(config.listColumn == ListColumnLayout(leftInset: 64, topInset: 0, width: 300))
        #expect(config.password == nil)
        // 密码框默认明文显示
        #expect(config.hidePasswordInput == false)
    }

    @Test func maskModeDefaultsToFullWithEmptyWhitelist() throws {
        #expect(AppConfig.default.maskMode == .full)
        #expect(AppConfig.default.whitelist.isEmpty)
        #expect(AppConfig.default.preciseListColumn == nil)

        // 旧版本写出的配置没有这三个字段
        let legacy = #"{"schemaVersion": 1, "listColumn": {"leftInset": 60, "topInset": 246, "width": 242}, "hidePasswordInput": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        #expect(config.maskMode == .full)
        #expect(config.whitelist.isEmpty)
        #expect(config.preciseListColumn == nil)
        #expect(config.listColumnLayout(for: config.maskMode) == ListColumnLayout(leftInset: 60, topInset: 246, width: 242))
    }

    @Test func unknownMaskModeFallsBackToFull() throws {
        let json = #"{"maskMode": "blur", "whitelist": ["文件传输助手"]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.maskMode == .full)
        #expect(config.whitelist == ["文件传输助手"])
    }

    @Test func appearanceModeDefaultsToSystemForLegacyConfig() throws {
        #expect(AppConfig.default.appearanceMode == .system)
        let legacy = #"{"schemaVersion": 1, "maskMode": "precise", "whitelist": ["文件传输助手"], "hidePasswordInput": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        #expect(config == AppConfig(maskMode: .precise, whitelist: ["文件传输助手"], hidePasswordInput: true))
    }

    @Test func unknownAppearanceModeFallsBackToSystem() throws {
        let json = #"{"appearanceMode": "sepia", "maskMode": "precise", "hidePasswordInput": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config == AppConfig(maskMode: .precise, hidePasswordInput: true))
    }

    @Test(arguments: [AppearanceMode.system, .light, .dark])
    func appearanceModeRoundTrips(_ mode: AppearanceMode) throws {
        let store = temporaryStore()
        var config = fullConfig
        config.appearanceMode = mode
        try store.save(config)
        #expect(try store.load() == config)
    }

    /// 精准遮挡没有校准过时，沿用整块遮挡的左边距和宽度，上边距为 0；校准后两种方式各用各的。
    @Test func preciseLayoutIsDerivedUntilCalibrated() {
        let fullLayout = ListColumnLayout(leftInset: 60, topInset: 246, width: 242)
        var config = AppConfig(listColumn: fullLayout)
        #expect(config.listColumnLayout(for: .full) == fullLayout)
        #expect(config.listColumnLayout(for: .precise) == ListColumnLayout(leftInset: 60, topInset: 0, width: 242))

        let preciseLayout = ListColumnLayout(leftInset: 58, topInset: 40, width: 250)
        config.preciseListColumn = preciseLayout
        #expect(config.listColumnLayout(for: .precise) == preciseLayout)
        #expect(config.listColumnLayout(for: .full) == fullLayout)
    }

    /// 遮挡方式和白名单总是写出；没有校准过的精准遮挡布局不写出，读回来仍然按整块遮挡的布局推导。
    @Test func uncalibratedPreciseLayoutIsNotWritten() throws {
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.default)) as? [String: Any])
        #expect(encoded["maskMode"] as? String == "full")
        #expect(encoded["whitelist"] as? [String] == [])
        #expect(encoded["preciseListColumn"] == nil)
    }

    @Test func corruptFileThrows() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
    }

    /// 两端共用 shared/config.schema.json：保证 Swift 模型写出的字段与 schema 完全一致（不多也不少）。
    /// 用所有字段都有值的配置检查，因为值为空的可选字段不会写出。
    @Test func encodedFieldsMatchSharedSchema() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuietChatCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // QuietChatCore
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()
        let schemaData = try Data(contentsOf: repositoryRoot.appending(components: "shared", "config.schema.json"))
        let schema = try #require(try JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        try expectSameFields(schema: schema, value: encoded, path: "$")
        let properties = try #require(schema["properties"] as? [String: Any])
        let appearance = try #require(properties["appearanceMode"] as? [String: Any])
        #expect(appearance["enum"] as? [String] == [AppearanceMode.system, .light, .dark].map(\.rawValue))
        #expect(appearance["default"] as? String == AppearanceMode.system.rawValue)
    }

    private func expectSameFields(schema: [String: Any], value: [String: Any], path: String) throws {
        let properties = try #require(schema["properties"] as? [String: Any], "schema 中 \(path) 缺少 properties")
        #expect(Set(properties.keys) == Set(value.keys), "\(path) 的字段与 schema 不一致")
        for (key, child) in value {
            guard let childValue = child as? [String: Any], let childSchema = properties[key] as? [String: Any] else { continue }
            try expectSameFields(schema: childSchema, value: childValue, path: "\(path).\(key)")
        }
    }
}
