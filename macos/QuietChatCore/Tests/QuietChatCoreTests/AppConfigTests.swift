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

    @Test func savedConfigRoundTrips() throws {
        let store = temporaryStore()
        let config = AppConfig(listColumn: ListColumnLayout(leftInset: 70, topInset: 12, width: 300))
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test func missingFieldsFallBackToDefaultsAndUnknownFieldsAreIgnored() throws {
        let json = #"{"listColumn": {"width": 300}, "fromTheFuture": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(config.listColumn == ListColumnLayout(leftInset: 64, topInset: 0, width: 300))
    }

    @Test func corruptFileThrows() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
    }

    /// 两端共用 shared/config.schema.json：这里保证 Swift 模型写出的字段与 schema 完全一致（不多也不少）。
    @Test func encodedFieldsMatchSharedSchema() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuietChatCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // QuietChatCore
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()
        let schemaData = try Data(contentsOf: repositoryRoot.appending(components: "shared", "config.schema.json"))
        let schema = try #require(try JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.default)) as? [String: Any])
        try expectSameFields(schema: schema, value: encoded, path: "$")
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
