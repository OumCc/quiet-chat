import Foundation
import Testing
@testable import QuietChatCore

struct ShortcutTimingTests {
    @Test func baselineAndZeroKeepTheirMeaning() throws {
        #expect(ShortcutTiming.baseline == ShortcutTiming(searchOpenMs: 150, selectAllMs: 50, resultsMs: 500))
        #expect(ShortcutTiming.baseline.totalMs == 700)
        let zero = ShortcutTiming(searchOpenMs: 0, selectAllMs: 0, resultsMs: 0)
        #expect(zero.totalMs == 0)
        #expect(try JSONDecoder().decode(ShortcutTiming.self, from: JSONEncoder().encode(zero)) == zero)
    }

    @Test func customMidpointsRoundTripWithoutDerivedFields() throws {
        let timing = ShortcutTiming(searchOpenMs: 56, selectAllMs: 12, resultsMs: 187)
        let data = try JSONEncoder().encode(timing)
        #expect(try JSONDecoder().decode(ShortcutTiming.self, from: data) == timing)
        let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(fields == ["searchOpenMs": 56, "selectAllMs": 12, "resultsMs": 187])
    }

    @Test func missingStagesFallBackIndependently() throws {
        let data = Data(#"{"selectAllMs":12,"futureField":42}"#.utf8)
        let timing = try JSONDecoder().decode(ShortcutTiming.self, from: data)
        #expect(timing == ShortcutTiming(searchOpenMs: 150, selectAllMs: 12, resultsMs: 500))
    }

    @Test(arguments: ["-1", "151", "1.5", "true", "null", "\"fast\"", "[]", "{}", "1e100"])
    func invalidSearchStagePreservesOtherStages(_ invalid: String) throws {
        let data = Data("{\"searchOpenMs\":\(invalid),\"selectAllMs\":12,\"resultsMs\":125}".utf8)
        let timing = try JSONDecoder().decode(ShortcutTiming.self, from: data)
        #expect(timing == ShortcutTiming(searchOpenMs: 150, selectAllMs: 12, resultsMs: 125))
    }

    @Test func invalidLaterStagesPreserveValidSearchStage() throws {
        let data = Data(#"{"searchOpenMs":56,"selectAllMs":51,"resultsMs":-1}"#.utf8)
        let timing = try JSONDecoder().decode(ShortcutTiming.self, from: data)
        #expect(timing == ShortcutTiming(searchOpenMs: 56, selectAllMs: 50, resultsMs: 500))
    }

    @Test func initializerCannotCreateOutOfRangeTiming() {
        #expect(ShortcutTiming(searchOpenMs: -1, selectAllMs: Int.max, resultsMs: 501) == .baseline)
    }
}
