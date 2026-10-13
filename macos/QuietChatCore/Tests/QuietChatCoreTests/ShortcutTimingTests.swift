import Foundation
import Testing
@testable import QuietChatCore

struct ShortcutTimingTests {
    @Test func baselineIsZeroAndRoundTrips() throws {
        let zero = ShortcutTiming(searchOpenMs: 0, selectAllMs: 0, resultsMs: 0)
        #expect(ShortcutTiming.baseline == zero)
        #expect(ShortcutTiming().totalMs == 0)
        #expect(try JSONDecoder().decode(ShortcutTiming.self, from: JSONEncoder().encode(zero)) == .baseline)
    }

    @Test(arguments: [
        ShortcutTiming(searchOpenMs: 75, selectAllMs: 25, resultsMs: 250),
        ShortcutTiming(searchOpenMs: 150, selectAllMs: 50, resultsMs: 500),
    ])
    func nonzeroPresetAndOriginalUpperBoundsRemainValid(_ timing: ShortcutTiming) throws {
        #expect(timing.searchOpenMs > 0)
        #expect(timing.selectAllMs > 0)
        #expect(timing.resultsMs > 0)
        #expect(try JSONDecoder().decode(ShortcutTiming.self, from: JSONEncoder().encode(timing)) == timing)
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
        #expect(timing == ShortcutTiming(searchOpenMs: 0, selectAllMs: 12, resultsMs: 0))
    }

    @Test(arguments: ["-1", "151", "1.5", "true", "null", "\"fast\"", "[]", "{}", "1e100"])
    func invalidSearchStagePreservesOtherStages(_ invalid: String) throws {
        let data = Data("{\"searchOpenMs\":\(invalid),\"selectAllMs\":12,\"resultsMs\":125}".utf8)
        let timing = try JSONDecoder().decode(ShortcutTiming.self, from: data)
        #expect(timing == ShortcutTiming(searchOpenMs: 0, selectAllMs: 12, resultsMs: 125))
    }

    @Test func invalidLaterStagesPreserveValidSearchStage() throws {
        let data = Data(#"{"searchOpenMs":56,"selectAllMs":51,"resultsMs":-1}"#.utf8)
        let timing = try JSONDecoder().decode(ShortcutTiming.self, from: data)
        #expect(timing == ShortcutTiming(searchOpenMs: 56, selectAllMs: 0, resultsMs: 0))
    }

    @Test func initializerCannotCreateOutOfRangeTiming() {
        #expect(ShortcutTiming(searchOpenMs: -1, selectAllMs: Int.max, resultsMs: 501) == .baseline)
        #expect(ShortcutTiming(searchOpenMs: 151, selectAllMs: 25, resultsMs: 500)
            == ShortcutTiming(searchOpenMs: 0, selectAllMs: 25, resultsMs: 500))
        #expect(ShortcutTiming(searchOpenMs: 150, selectAllMs: 51, resultsMs: 250)
            == ShortcutTiming(searchOpenMs: 150, selectAllMs: 0, resultsMs: 250))
        #expect(ShortcutTiming(searchOpenMs: 75, selectAllMs: 50, resultsMs: 501)
            == ShortcutTiming(searchOpenMs: 75, selectAllMs: 50, resultsMs: 0))
    }
}
