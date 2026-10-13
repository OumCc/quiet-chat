// 客户端更新：先取得本地检查同意，再由 Sparkle 调度、校验和安装；后台只给菜单提醒。
// 更新开关沿用 Sparkle UserDefaults，聊天配置不参与请求或更新状态。

import AppKit
import QuietChatCore
import Sparkle

// Sparkle 的 UI 回调保证主线程，但该 Objective-C delegate 没有声明 actor。
/** 装配标准更新器和菜单提醒；必须由应用持有，所有交互都在主线程发生。 */
@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private let preferences: UpdatePreferences
    private var reminder = UpdateReminder()
    private var isStarted = false
    private var checkObservation: NSKeyValueObservation?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /** 更新提醒或可检查状态改变后通知菜单刷新，不改变应用锁定状态。 */
    var onChange: (() -> Void)?
    /** 用户打开更新 UI 前停止旧快捷任务，后台提醒不会触发此回调。 */
    var onUserInteraction: (() -> Void)?
    /** 替换后重启之前执行应用侧清理；安装本身仍由 Sparkle 负责。 */
    var onRelaunch: (() -> Void)?

    /** 共享应用更新偏好，确保首次询问和升级检测使用同一偏好域。 */
    init(preferences: UpdatePreferences) {
        self.preferences = preferences
        super.init()
    }

    /** 标准窗口可被检查动作唤回；下载忙碌时返回 false。 */
    var canCheckForUpdates: Bool { isStarted && controller.updater.canCheckForUpdates }
    /** 用户保存的检查选择，不代表允许自动安装。 */
    var automaticallyChecksForUpdates: Bool { controller.updater.automaticallyChecksForUpdates }
    /** 尚未获得用户关注的后台版本；不暴露整个 appcast 到菜单。 */
    var availableUpdateVersion: String? { reminder.availableVersion }
    /** 状态对应的中文操作标题，供菜单与验证宿主使用。 */
    var menuTitle: String { reminder.menuTitle }

    /** 启动后先询问未作出的选择；Info.plist 默认关闭检查，弹窗期间不会联网。 */
    func start() {
        do {
            try controller.updater.start()
            isStarted = true
        } catch {
            Log.updates.error("更新器启动失败：\(error.localizedDescription, privacy: .public)")
            return
        }
        controller.updater.sendsSystemProfile = false
        checkObservation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
        if preferences.automaticCheckConsent == nil {
            onUserInteraction?()
            let alert = NSAlert()
            alert.messageText = "允许自动检查 QuietChat 更新吗？"
            alert.informativeText = "允许后每天访问 GitHub 检查新版本。聊天内容、白名单和密码不会上传；发现更新只在菜单栏提醒，安装前仍需你确认。你可以随时在菜单关闭。"
            alert.addButton(withTitle: "允许自动检查")
            alert.addButton(withTitle: "暂不开启")
            NSApp.activate(ignoringOtherApps: true)
            controller.updater.automaticallyChecksForUpdates = alert.runModal() == .alertFirstButtonReturn
        }
        onChange?()
    }

    /** 用户主动改变检查偏好，Sparkle 同时保存选择并重置调度。 */
    func toggleAutomaticChecks() {
        guard isStarted else { return }
        controller.updater.automaticallyChecksForUpdates.toggle()
        onChange?()
    }

    /** 用户点击后检查或唤回已有更新窗口；只读或转移位置先提供安装说明。 */
    func checkForUpdates() {
        onUserInteraction?()
        if let problem = installationLocationProblem {
            showDownloadHelp(message: problem)
            return
        }
        guard isStarted else {
            showDownloadHelp(message: "更新功能配置不完整，请从 GitHub 下载新版并替换应用。")
            return
        }
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /** 打开原安装包页面，作为系统阻止安装或网络失败时的人工入口。 */
    func openDownloads() {
        guard let url = URL(string: "https://github.com/OumCc/quiet-chat/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    private var installationLocationProblem: String? {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if readOnly || url.path.contains("/AppTranslocation/") {
            return "请先退出 QuietChat，将它从安装包复制到“应用程序”，再从那里打开并检查更新。"
        }
        return nil
    }

    private func showDownloadHelp(message: String) {
        let alert = NSAlert()
        alert.messageText = "暂时无法自动安装更新"
        alert.informativeText = message
        alert.addButton(withTitle: "下载安装包")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openDownloads() }
    }

    /** 禁止在只读位置更新；后台失败沿用日志路径，不弹新窗口。 */
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let message = installationLocationProblem {
            throw NSError(domain: "QuietChat.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /** 后台检查失败只记录诊断；手动错误由 Sparkle 标准窗口展示。 */
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.updates.notice("更新未完成：\(error.localizedDescription, privacy: .public)")
    }

    /** 重启交接前通知装配层，取消未结束的快捷操作。 */
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onRelaunch?()
    }

    /** 由菜单标记承担后台提醒，避免没有 Dock 图标的应用丢失提醒。 */
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /** 自动检查永不把更新窗口带到前台；菜单点击由标准 user driver 接管。 */
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    /** 仅后台提醒记录版本；主动展示只执行应用侧输入清理。 */
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            onUserInteraction?()
        } else {
            reminder.show(version: update.displayVersionString)
            onChange?()
        }
    }

    /** 用户关注版本后移除圆点，后续安装或稍后提醒由标准窗口处理。 */
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearReminder()
    }

    /** 取消、跳过或失败结束会话时，不保留陈旧菜单提醒。 */
    func standardUserDriverWillFinishUpdateSession() {
        clearReminder()
    }

    private func clearReminder() {
        reminder.clear()
        onChange?()
    }

    /** 说明真实重启和临时签名代价；标准窗口仍提供用户确认按钮。 */
    func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotes: NSAttributedString, forUpdate update: SUAppcastItem,
        withBundleDisplayVersion displayVersion: String, bundleVersion: String
    ) -> NSAttributedString? {
        let text = NSMutableAttributedString(
            string: "更新会重启 QuietChat 并暂时停止遮罩，请先保存白名单修改或完成校准。升级后可能需要重新授予辅助功能权限。\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        text.append(releaseNotes)
        return text
    }
}
