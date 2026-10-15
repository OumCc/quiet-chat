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

    @Test func shortcutTimingDefaultsToZeroWithCurrentVersion() {
        #expect(AppConfig.default.shortcutTiming == ShortcutTiming(searchOpenMs: 0, selectAllMs: 0, resultsMs: 0))
        #expect(AppConfig.default.shortcutTimingVersion == 1)
        #expect(AppConfig.default.schemaVersion == 1)
    }

    /// 所有字段都有值的配置，用来检查读写和 schema 一致性。
    private let fullConfig = AppConfig(
        listColumn: ListColumnLayout(leftInset: 70, topInset: 12, width: 300),
        maskMode: .shortcuts,
        whitelist: ["文件传输助手", "滴答清单"],
        preciseListColumn: ListColumnLayout(leftInset: 70, topInset: 0, width: 300),
        password: PasswordRecord(iterations: 100_000, salt: "c2FsdA==", hash: "aGFzaA=="),
        hidePasswordInput: true,
        appearanceMode: .dark,
        shortcutTiming: ShortcutTiming(searchOpenMs: 56, selectAllMs: 12, resultsMs: 125))

    @Test func savedConfigRoundTrips() throws {
        let store = temporaryStore()
        try store.save(fullConfig)
        #expect(try store.load() == fullConfig)
    }

    @Test func legacyConfigWithoutTimingPreservesOtherSettingsAndFile() throws {
        let store = temporaryStore()
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        legacy.removeValue(forKey: "shortcutTiming")
        legacy.removeValue(forKey: "shortcutTimingVersion")
        let originalData = try JSONSerialization.data(withJSONObject: legacy)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalData.write(to: store.fileURL)

        var expected = fullConfig
        expected.shortcutTiming = .baseline
        #expect(try store.load() == expected)
        #expect(try Data(contentsOf: store.fileURL) == originalData)
        #expect(expected.schemaVersion == 1)
    }

    @Test(arguments: [
        ShortcutTiming(searchOpenMs: 150, selectAllMs: 50, resultsMs: 500),
        ShortcutTiming(searchOpenMs: 75, selectAllMs: 25, resultsMs: 250),
        ShortcutTiming(searchOpenMs: 56, selectAllMs: 12, resultsMs: 125),
    ])
    func legacyTimingResetsWithoutRewritingFile(_ timing: ShortcutTiming) throws {
        let store = temporaryStore()
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        legacy.removeValue(forKey: "shortcutTimingVersion")
        legacy["shortcutTiming"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
        let originalData = try JSONSerialization.data(withJSONObject: legacy)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalData.write(to: store.fileURL)

        var expected = fullConfig
        expected.shortcutTiming = .baseline
        #expect(try store.load() == expected)
        #expect(try Data(contentsOf: store.fileURL) == originalData)
        #expect(expected.shortcutTimingVersion == 1)
        #expect(expected.schemaVersion == 1)
    }

    @Test(arguments: ["0", "2", "-1", "1.5", "true", "null", "\"1\"", "[]", "{}", "1e100"])
    func invalidTimingVersionResetsAllStages(_ invalid: String) throws {
        var values = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        values["shortcutTimingVersion"] = try JSONSerialization.jsonObject(with: Data(invalid.utf8), options: [.fragmentsAllowed])
        var expected = fullConfig
        expected.shortcutTiming = .baseline
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: values)) == expected)
    }

    @Test func migratedTimingChoiceSurvivesSaveAndReload() throws {
        let store = temporaryStore()
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        legacy.removeValue(forKey: "shortcutTimingVersion")
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.fileURL)

        var loaded = try store.load()
        #expect(loaded.shortcutTiming == .baseline)
        loaded.shortcutTiming = ShortcutTiming(searchOpenMs: 75, selectAllMs: 25, resultsMs: 250)
        try store.save(loaded)

        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(saved["shortcutTimingVersion"] as? Int == 1)
        #expect(saved["schemaVersion"] as? Int == 1)
        var expected = fullConfig
        expected.shortcutTiming = loaded.shortcutTiming
        #expect(try store.load() == expected)
    }

    @Test func currentTimingFieldsFallBackIndependently() throws {
        var values = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        values["shortcutTiming"] = ["searchOpenMs": -1, "selectAllMs": 25]
        var expected = fullConfig
        expected.shortcutTiming = ShortcutTiming(searchOpenMs: 0, selectAllMs: 25, resultsMs: 0)
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: values)) == expected)
    }

    @Test(arguments: ["null", "false", "\"fast\"", "[]", "123"])
    func invalidTimingObjectDoesNotDiscardOtherConfig(_ invalid: String) throws {
        var values = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        values["shortcutTiming"] = try JSONSerialization.jsonObject(with: Data(invalid.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: values)
        var expected = fullConfig
        expected.shortcutTiming = .baseline
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == expected)
    }

    @Test func timingUpdateAndRestoreRoundTripWithoutChangingOtherSettings() throws {
        let store = temporaryStore()
        var config = fullConfig
        config.shortcutTiming = ShortcutTiming(
            searchOpenMs: config.shortcutTiming.searchOpenMs,
            selectAllMs: config.shortcutTiming.selectAllMs,
            resultsMs: 0)
        try store.save(config)
        #expect(try store.load() == config)
        #expect(config.shortcutTiming.searchOpenMs == fullConfig.shortcutTiming.searchOpenMs)
        #expect(config.shortcutTiming.selectAllMs == fullConfig.shortcutTiming.selectAllMs)

        config.shortcutTiming = .baseline
        try store.save(config)
        var expected = fullConfig
        expected.shortcutTiming = .baseline
        #expect(try store.load() == expected)
    }

    @Test func legacyPrecisePreservesAllFieldsAndMigratesOnSave() throws {
        let store = temporaryStore()
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullConfig)) as? [String: Any])
        legacy["maskMode"] = "precise"
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyData.write(to: store.fileURL)

        let loaded = try store.load()
        #expect(loaded == fullConfig)
        #expect(try Data(contentsOf: store.fileURL) == legacyData)
        try store.save(loaded)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(saved["maskMode"] as? String == "shortcuts")
        #expect(saved["schemaVersion"] as? Int == 1)
        #expect(try store.load() == fullConfig)
    }

    @Test(arguments: [MaskMode.full, .shortcuts])
    func maskModeRoundTripsWithEmptyWhitelist(_ mode: MaskMode) throws {
        let store = temporaryStore()
        let config = AppConfig(maskMode: mode)
        try store.save(config)
        #expect(try store.load() == config)
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
        #expect(config == AppConfig(maskMode: .shortcuts, whitelist: ["文件传输助手"], hidePasswordInput: true))
    }

    @Test func unknownAppearanceModeFallsBackToSystem() throws {
        let json = #"{"appearanceMode": "sepia", "maskMode": "precise", "hidePasswordInput": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config == AppConfig(maskMode: .shortcuts, hidePasswordInput: true))
    }

    @Test(arguments: [AppearanceMode.system, .light, .dark])
    func appearanceModeRoundTrips(_ mode: AppearanceMode) throws {
        let store = temporaryStore()
        var config = fullConfig
        config.appearanceMode = mode
        try store.save(config)
        #expect(try store.load() == config)
    }

    /// 快捷入口方式没有校准过时，沿用整块遮挡的左边距和宽度，上边距为 0；校准后两种方式各用各的。
    @Test func shortcutLayoutIsDerivedUntilCalibrated() {
        let fullLayout = ListColumnLayout(leftInset: 60, topInset: 246, width: 242)
        var config = AppConfig(listColumn: fullLayout)
        #expect(config.listColumnLayout(for: .full) == fullLayout)
        #expect(config.listColumnLayout(for: .shortcuts) == ListColumnLayout(leftInset: 60, topInset: 0, width: 242))

        let preciseLayout = ListColumnLayout(leftInset: 58, topInset: 40, width: 250)
        config.preciseListColumn = preciseLayout
        #expect(config.listColumnLayout(for: .shortcuts) == preciseLayout)
        #expect(config.listColumnLayout(for: .full) == fullLayout)
    }

    /// 遮挡方式和白名单总是写出；没有校准过的快捷入口方式布局不写出，读回来仍然按整块遮挡的布局推导。
    @Test func uncalibratedShortcutLayoutIsNotWritten() throws {
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
        let maskMode = try #require(properties["maskMode"] as? [String: Any])
        #expect(maskMode["enum"] as? [String] == [MaskMode.full.rawValue, MaskMode.shortcuts.rawValue, "precise"])
        #expect(maskMode["default"] as? String == MaskMode.full.rawValue)
        let appearance = try #require(properties["appearanceMode"] as? [String: Any])
        #expect(appearance["enum"] as? [String] == [AppearanceMode.system, .light, .dark].map(\.rawValue))
        #expect(appearance["default"] as? String == AppearanceMode.system.rawValue)
        let timing = try #require(properties["shortcutTiming"] as? [String: Any])
        let timingProperties = try #require(timing["properties"] as? [String: Any])
        let defaults = try #require(timing["default"] as? [String: Int])
        for (key, maximum) in [("searchOpenMs", 150), ("selectAllMs", 50), ("resultsMs", 500)] {
            let field = try #require(timingProperties[key] as? [String: Any])
            #expect(field["type"] as? String == "integer")
            #expect(field["minimum"] as? Int == 0)
            #expect(field["maximum"] as? Int == maximum)
            #expect(field["default"] as? Int == 0)
            #expect(defaults[key] == 0)
        }
        let timingVersion = try #require(properties["shortcutTimingVersion"] as? [String: Any])
        #expect(timingVersion["type"] as? String == "integer")
        #expect(timingVersion["const"] as? Int == AppConfig.currentShortcutTimingVersion)
        #expect(timingVersion["default"] as? Int == AppConfig.currentShortcutTimingVersion)
        #expect(encoded["shortcutTimingVersion"] as? Int == AppConfig.currentShortcutTimingVersion)
        let timed = try #require(properties["timedControl"] as? [String: Any])
        let timedProperties = try #require(timed["properties"] as? [String: Any])
        let enabled = try #require(timedProperties["enabled"] as? [String: Any])
        let minutes = try #require(timedProperties["durationMinutes"] as? [String: Any])
        #expect(enabled["default"] as? Bool == TimedControlSettings.default.enabled)
        #expect(minutes["default"] as? Int == TimedControlSettings.default.durationMinutes)
        #expect(minutes["minimum"] as? Int == TimedControlSettings.durationRange.lowerBound)
        #expect(minutes["maximum"] as? Int == TimedControlSettings.durationRange.upperBound)
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
