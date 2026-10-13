import Foundation
import Testing
@testable import QuietChatCore

@MainActor
struct UpdatePreferencesTests {
    @Test func consentDistinguishesFirstLaunchFromRefusalAndSurvivesNewReader() throws {
        let name = "QuietChat.UpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(UpdatePreferences(defaults: defaults).automaticCheckConsent == nil)

        defaults.set(false, forKey: UpdatePreferences.automaticChecksKey)
        #expect(UpdatePreferences(defaults: defaults).automaticCheckConsent == false)
        defaults.set(true, forKey: UpdatePreferences.automaticChecksKey)
        #expect(UpdatePreferences(defaults: defaults).automaticCheckConsent == true)
    }

    @Test func buildChangeIsOnlyReportedOnceIncludingAfterRelaunch() throws {
        let name = "QuietChat.UpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UpdatePreferences(defaults: defaults)
        #expect(!preferences.recordLaunch(buildVersion: "100"))
        #expect(!preferences.recordLaunch(buildVersion: "100"))
        #expect(preferences.recordLaunch(buildVersion: "101"))
        #expect(!UpdatePreferences(defaults: defaults).recordLaunch(buildVersion: "101"))
    }

    @Test func reminderDependsOnBuildAndOnlyRequiredPermissions() {
        for changed in [false, true] {
            for ax in [false, true] {
                for keyboardNeeded in [false, true] {
                    for keyboardGranted in [false, true] {
                        let result = UpdatePreferences.needsPermissionReminder(
                            buildChanged: changed, hasAccessibility: ax,
                            needsKeyboardAccess: keyboardNeeded, canPostEvents: keyboardGranted)
                        if !changed || (ax && (!keyboardNeeded || keyboardGranted)) {
                            #expect(!result)
                        } else {
                            #expect(result)
                        }
                    }
                }
            }
        }
    }

    @Test func updateAttentionAndFailedSessionDoNotLeaveOldMenuVersion() {
        var reminder = UpdateReminder()
        #expect(reminder.menuTitle == "检查更新…")
        reminder.show(version: "1.1.1")
        #expect(reminder.menuTitle == "安装更新 v1.1.1…")
        reminder.clear()
        #expect(reminder.availableVersion == nil)
        reminder.show(version: "1.1.2")
        #expect(reminder.menuTitle == "安装更新 v1.1.2…")
        reminder.clear()
        #expect(reminder.menuTitle == "检查更新…")
    }
}
