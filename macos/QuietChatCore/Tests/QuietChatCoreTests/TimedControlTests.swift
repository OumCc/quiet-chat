// 固定时刻验证周期与配置，不等待真实计时，不读取用户配置。

import Foundation
import Testing
@testable import QuietChatCore

struct TimedControlTests {
    private let start = ContinuousClock.now
    private let settings = TimedControlSettings(enabled: true, durationMinutes: 30)

    private func active() -> TimedControlState {
        var state = TimedControlState()
        #expect(state.attemptUnlock(PasswordVerifier.defaultPassword, requirement: .password,
                                   settings: settings, passwordRecord: nil, at: start) == .unlocked)
        return state
    }

    @Test func enabledSettingsWaitForSuccessfulOriginalPassword() {
        var state = TimedControlState()
        #expect(state.deadline == nil)
        #expect(state.requirement(at: start) == .password)
        #expect(state.attemptUnlock("wrong", requirement: .password, settings: settings,
                                   passwordRecord: nil, at: start) == .incorrect)
        #expect(state.deadline == nil)
        #expect(state.attemptUnlock(PasswordVerifier.defaultPassword, requirement: .password,
                                   settings: settings, passwordRecord: nil, at: start) == .unlocked)
        #expect(state.deadline == start.advanced(by: .seconds(1800)))
    }

    @Test func disabledModeNeverStartsCycle() {
        var state = TimedControlState()
        #expect(state.attemptUnlock(PasswordVerifier.defaultPassword, requirement: .password,
                                   settings: .default, passwordRecord: nil, at: start) == .unlocked)
        #expect(state.deadline == nil)
    }

    @Test func repeatedUnlockAndRelockingDoNotExtendDeadline() {
        var state = active()
        let original = state.deadline
        var lock = LockState()
        lock.unlock()
        lock.lock()
        #expect(state.attemptUnlock(UnlockRequirement.keyboardSequenceText, requirement: .keyboardSequence,
                                   settings: settings, passwordRecord: nil,
                                   at: start.advanced(by: .seconds(600))) == .unlocked)
        #expect(state.deadline == original)
        #expect(state.remainingSeconds(at: start.advanced(by: .seconds(600))) == 1200)
    }

    @Test(arguments: [PasswordVerifier.defaultPassword, "QWERTYUIOPASDFGHJKLZXCVBNM",
                      " qwertyuiopasdfghjklzxcvbnm", "qwertyuiopasdfghjklzxcvbnm\n", "qwertyuiop", ""])
    func activeCycleRejectsOtherInputs(_ input: String) {
        var state = active()
        let original = state
        #expect(state.attemptUnlock(input, requirement: .keyboardSequence, settings: settings,
                                   passwordRecord: nil, at: start) == .incorrect)
        #expect(state == original)
    }

    @Test func staleRequirementDoesNotReinterpretInput() {
        var state = active()
        let deadline = start.advanced(by: .seconds(1800))
        #expect(state.attemptUnlock(UnlockRequirement.keyboardSequenceText, requirement: .keyboardSequence,
                                   settings: settings, passwordRecord: nil, at: deadline) == .requirementChanged)
        #expect(state.requirement(at: deadline) == .password)
        #expect(state.attemptUnlock(PasswordVerifier.defaultPassword, requirement: .password,
                                   settings: settings, passwordRecord: nil, at: start) == .requirementChanged)
    }

    @Test func expiryAndNextOriginalUnlockStartNewCycle() {
        var state = active()
        let deadline = start.advanced(by: .seconds(1800))
        #expect(state.requirement(at: deadline.advanced(by: .nanoseconds(-1))) == .keyboardSequence)
        #expect(state.remainingSeconds(at: deadline.advanced(by: .nanoseconds(-1))) == 1)
        #expect(state.requirement(at: deadline) == .password)
        state.expireIfNeeded(at: deadline)
        #expect(state.deadline == nil)
        #expect(state.attemptUnlock(PasswordVerifier.defaultPassword, requirement: .password,
                                   settings: settings, passwordRecord: nil, at: deadline) == .unlocked)
        #expect(state.deadline == start.advanced(by: .seconds(3600)))
    }

    @Test func durationChangeRestartsFromSaveTimeAndSameSelectionDoesNothing() {
        var state = active()
        let later = start.advanced(by: .seconds(1200))
        state.applySettings(settings, replacing: settings, at: later)
        #expect(state.deadline == start.advanced(by: .seconds(1800)))
        let changed = TimedControlSettings(enabled: true, durationMinutes: 45)
        state.applySettings(changed, replacing: settings, at: later)
        #expect(state.deadline == later.advanced(by: .seconds(2700)))
    }

    @Test func enablingOrEditingWaitingSettingsDoesNotStartTimer() {
        var state = TimedControlState()
        state.applySettings(settings, replacing: .default, at: start)
        state.applySettings(TimedControlSettings(enabled: true, durationMinutes: 45), replacing: settings, at: start)
        #expect(state.deadline == nil)
    }

    @Test func disablingClearsAndExpiredChangeWaitsForNextUnlock() {
        var state = active()
        state.applySettings(.default, replacing: settings, at: start)
        #expect(state.deadline == nil)
        state = active()
        state.applySettings(TimedControlSettings(enabled: true, durationMinutes: 45), replacing: settings,
                            at: start.advanced(by: .seconds(1800)))
        #expect(state.deadline == nil)
    }

    @Test func passwordChangesCannotReplaceFixedSequence() throws {
        var state = active()
        let record = try #require(PasswordVerifier.makeRecord(for: "new password"))
        #expect(state.attemptUnlock("new password", requirement: .keyboardSequence, settings: settings,
                                   passwordRecord: record, at: start) == .incorrect)
        #expect(state.attemptUnlock(UnlockRequirement.keyboardSequenceText, requirement: .keyboardSequence,
                                   settings: settings, passwordRecord: nil, at: start) == .unlocked)
        let later = start.advanced(by: .seconds(1800))
        #expect(state.attemptUnlock("new password", requirement: .password, settings: settings,
                                   passwordRecord: record, at: later) == .unlocked)
    }

    @Test func elapsedTimeIncludesLongGapsAndNewInstanceHasNoCycle() {
        let state = active()
        #expect(state.remainingSeconds(at: start.advanced(by: .seconds(10_000))) == 0)
        #expect(TimedControlState().requirement(at: start) == .password)
        #expect(TimedControlState().deadline == nil)
    }
}

struct TimedControlConfigTests {
    @Test func defaultsAndLimitsAreStable() {
        #expect(TimedControlSettings.default == TimedControlSettings(enabled: false, durationMinutes: 30))
        #expect(TimedControlSettings(durationMinutes: 1).durationMinutes == 1)
        #expect(TimedControlSettings(durationMinutes: 1440).durationMinutes == 1440)
        #expect(TimedControlSettings(durationMinutes: 0).durationMinutes == 30)
        #expect(TimedControlSettings(durationMinutes: 1441).durationMinutes == 30)
        #expect(TimedControlSettings.presets == [15, 30, 45, 60])
    }

    @Test(arguments: ["null", "false", "123", "[]", "\"enabled\""])
    func invalidObjectPreservesOtherConfig(_ value: String) throws {
        let data = Data("{\"timedControl\":\(value),\"maskMode\":\"shortcuts\",\"hidePasswordInput\":true}".utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.timedControl == .default)
        #expect(config.maskMode == .shortcuts)
        #expect(config.hidePasswordInput)
    }

    @Test(arguments: ["0", "1441", "-1", "1.5", "true", "null", "\"30\"", "[]", "{}", "1e100"])
    func invalidMinutesKeepEnabledChoice(_ value: String) throws {
        let data = Data("{\"enabled\":true,\"durationMinutes\":\(value)}".utf8)
        #expect(try JSONDecoder().decode(TimedControlSettings.self, from: data)
                == TimedControlSettings(enabled: true, durationMinutes: 30))
    }

    @Test func missingAndInvalidFieldsFallBackIndependently() throws {
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).timedControl == .default)
        #expect(try JSONDecoder().decode(TimedControlSettings.self, from: Data("{}".utf8)) == .default)
        let data = Data(#"{"enabled":"yes","durationMinutes":45,"future":true}"#.utf8)
        #expect(try JSONDecoder().decode(TimedControlSettings.self, from: data)
                == TimedControlSettings(enabled: false, durationMinutes: 45))
    }

    @Test func legacyLoadDoesNotRewriteAndPreferencesRoundTripWithoutDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuietChatTimed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: directory.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"maskMode":"shortcuts","whitelist":["文件传输助手"],"hidePasswordInput":true}"#.utf8)
        try original.write(to: store.fileURL)
        var config = try store.load()
        #expect(config.timedControl == .default)
        #expect(try Data(contentsOf: store.fileURL) == original)
        config.timedControl = TimedControlSettings(enabled: true, durationMinutes: 1440)
        try store.save(config)
        #expect(try store.load() == config)
        #expect(config.schemaVersion == 1)
        let encoded = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let timed = try #require(encoded["timedControl"] as? [String: Any])
        #expect(Set(timed.keys) == ["enabled", "durationMinutes"])
        #expect(encoded["deadline"] == nil)
        #expect(config.whitelist == ["文件传输助手"])
        #expect(config.hidePasswordInput)
    }
}
