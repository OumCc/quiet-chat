import CoreGraphics
import Testing
@testable import QuietChatCore

struct PreciseRevealStateTests {
    private let bands = [CGRect(x: 60, y: 66, width: 242, height: 60), CGRect(x: 60, y: 194, width: 242, height: 60)]

    @Test func startsWithNothingRevealed() {
        #expect(PreciseRevealState().revealedBands.isEmpty)
    }

    @Test func revealsBandsWhenRecognitionFinishes() {
        var state = PreciseRevealState()
        let accepted = state.finishRecognition(generation: state.beginRecognition(), bands: bands)
        #expect(accepted)
        #expect(state.revealedBands == bands)
    }

    @Test func contentChangeHidesRevealedBandsImmediately() {
        var state = PreciseRevealState()
        state.finishRecognition(generation: state.beginRecognition(), bands: bands)
        state.contentChanged()
        #expect(state.revealedBands.isEmpty)
    }

    /// 识别期间内容又变了：这一轮的结果对应的是旧画面，不能采用。
    @Test func staleRecognitionResultIsDiscarded() {
        var state = PreciseRevealState()
        let stale = state.beginRecognition()
        state.contentChanged()
        let staleAccepted = state.finishRecognition(generation: stale, bands: bands)
        #expect(!staleAccepted)
        #expect(state.revealedBands.isEmpty)

        // 变化之后重新开始的一轮照常采用
        let freshAccepted = state.finishRecognition(generation: state.beginRecognition(), bands: bands)
        #expect(freshAccepted)
        #expect(state.revealedBands == bands)
    }

    @Test func resetHidesBandsAndInvalidatesEarlierGenerations() {
        var state = PreciseRevealState()
        state.finishRecognition(generation: state.beginRecognition(), bands: bands)
        let beforeReset = state.beginRecognition()
        state.reset()
        #expect(state.revealedBands.isEmpty)

        let accepted = state.finishRecognition(generation: beforeReset, bands: bands)
        #expect(!accepted)
        #expect(state.revealedBands.isEmpty)
    }

    /// 内容没有变化时，同一轮的结果可以重复提交（例如超时后重试），以最后一次为准。
    @Test func laterResultOfTheSameGenerationReplacesEarlierOne() {
        var state = PreciseRevealState()
        let generation = state.beginRecognition()
        state.finishRecognition(generation: generation, bands: [])
        let accepted = state.finishRecognition(generation: generation, bands: bands)
        #expect(accepted)
        #expect(state.revealedBands == bands)
    }
}
