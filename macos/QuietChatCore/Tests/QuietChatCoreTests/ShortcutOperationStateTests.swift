import Testing
@testable import QuietChatCore

struct ShortcutOperationStateTests {
    @Test func busyOperationRejectsAnotherStart() throws {
        var state = ShortcutOperationState()
        #expect(!state.isBusy)
        let started = state.begin()
        let id = try #require(started)
        #expect(state.isBusy)
        let rejected = state.begin()
        #expect(rejected == nil)
        #expect(state.isCurrent(id))
        let finished = state.finish(id)
        #expect(finished)
        #expect(!state.isBusy)
    }

    @Test func oldCompletionCannotFinishNewOperation() throws {
        var state = ShortcutOperationState()
        let first = state.begin()
        let old = try #require(first)
        state.cancel()
        #expect(!state.isCurrent(old))
        let second = state.begin()
        let current = try #require(second)
        #expect(current > old)
        let staleFinish = state.finish(old)
        #expect(!staleFinish)
        #expect(state.isCurrent(current))
        #expect(state.isBusy)
        let finished = state.finish(current)
        #expect(finished)
        let repeated = state.finish(current)
        #expect(!repeated)
    }

    @Test func cancelIsSafeWhenIdleAndInvalidatesCurrent() throws {
        var state = ShortcutOperationState()
        state.cancel()
        let started = state.begin()
        let id = try #require(started)
        state.cancel()
        state.cancel()
        let staleFinish = state.finish(id)
        #expect(!staleFinish)
        #expect(!state.isBusy)
    }
}
