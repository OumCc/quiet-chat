import CoreGraphics
import Foundation
import Testing
@testable import QuietChatCore

struct LockStateTests {
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func unlocked() -> LockState {
        var state = LockState()
        state.unlock()
        return state
    }

    @Test func startsLocked() {
        #expect(LockState().isLocked)
    }

    @Test func staysUnlockedWhileWindowIsOpenAnywhere() {
        var state = unlocked()
        let lockedWhenVisible = state.autoLockIfNeeded(for: WindowSnapshot(frame: frame, presence: .visible))
        // 切换桌面不锁定
        let lockedWhenElsewhere = state.autoLockIfNeeded(for: WindowSnapshot(frame: frame, presence: .onOtherSpace))
        #expect(!lockedWhenVisible)
        #expect(!lockedWhenElsewhere)
        #expect(!state.isLocked)
    }

    @Test func locksWhenWindowClosesOrDisappears() {
        var closed = unlocked()
        let lockedWhenClosed = closed.autoLockIfNeeded(for: WindowSnapshot(frame: frame, presence: .closed))
        #expect(lockedWhenClosed)
        #expect(closed.isLocked)

        var gone = unlocked()
        let lockedWhenGone = gone.autoLockIfNeeded(for: nil)
        #expect(lockedWhenGone)
        #expect(gone.isLocked)
    }

    @Test func reportsOnlyTheTransitionToLocked() {
        var state = LockState()
        let changed = state.autoLockIfNeeded(for: nil)
        #expect(!changed)
    }
}

struct PasswordVerifierTests {
    @Test func defaultPasswordWorksUntilChanged() {
        #expect(PasswordVerifier.verify("1234567890", against: nil))
        #expect(!PasswordVerifier.verify("123456789", against: nil))
    }

    @Test func customPasswordReplacesDefault() throws {
        let record = try #require(PasswordVerifier.makeRecord(for: "安静一点 quiet"))
        #expect(record.algorithm == "PBKDF2-SHA256")
        #expect(Data(base64Encoded: record.salt)?.count == 16)
        #expect(Data(base64Encoded: record.hash)?.count == 32)
        #expect(PasswordVerifier.verify("安静一点 quiet", against: record))
        #expect(!PasswordVerifier.verify("安静一点 quiet ", against: record))
        #expect(!PasswordVerifier.verify("1234567890", against: record))
    }

    @Test func saltIsRandomPerRecord() throws {
        let first = try #require(PasswordVerifier.makeRecord(for: "same"))
        let second = try #require(PasswordVerifier.makeRecord(for: "same"))
        #expect(first.salt != second.salt)
        #expect(first.hash != second.hash)
    }

    /// 标准测试向量：Windows 端的实现也应得到同样的结果。
    @Test func matchesKnownPBKDF2SHA256Vector() throws {
        let derived = try #require(PasswordVerifier.derive("password", salt: Data("salt".utf8), iterations: 1, length: 32))
        let hex = derived.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    @Test func malformedRecordNeverVerifies() {
        let record = PasswordRecord(iterations: 1, salt: "不是 base64", hash: "")
        #expect(!PasswordVerifier.verify("", against: record))
        let unknownAlgorithm = PasswordRecord(algorithm: "MD5", iterations: 1, salt: "", hash: "")
        #expect(!PasswordVerifier.verify("", against: unknownAlgorithm))
    }
}
