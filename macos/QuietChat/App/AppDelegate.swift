// 应用装配：加载配置、处理辅助功能授权、随微信进程启动/退出创建或销毁窗口跟踪器，
// 在任何可能改变遮罩位置或可见性的时刻刷新遮罩（刷新时机见 docs/architecture.md「刷新时机」），
// 并维护锁定状态：密码解锁、主窗口关闭时自动锁定（见「锁定与解锁」）。

import AppKit
import QuietChatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore(fileURL: ConfigStore.defaultFileURL)
    private var config = AppConfig.default
    private var lockState = LockState()
    private let permission = AccessibilityPermission()
    private let maskController = MaskController()
    private var statusMenu: StatusMenuController?
    private var refreshDriver: RefreshDriver?
    private var tracker: WeChatWindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherInstances()
        config = loadConfig()
        maskController.layout = config.listColumn
        maskController.onCalibrationFinished = { [weak self] layout in self?.saveListColumn(layout) }
        maskController.onUnlockAttempt = { [weak self] password in self?.attemptUnlock(with: password) ?? false }
        maskController.hidesPasswordInput = config.hidePasswordInput
        maskController.onPasswordVisibilityChange = { [weak self] hidden in self?.saveHidePasswordInput(hidden) }
        statusMenu = StatusMenuController(delegate: self)

        if permission.isGranted {
            startTracking()
        } else {
            Log.app.notice("辅助功能未授权，等待用户授权")
            permission.request()
            permission.waitForGrant { [weak self] in
                Log.app.notice("辅助功能已授权")
                self?.startTracking()
            }
        }
    }

    /// 只保留一个实例：两个实例会画出两层遮罩。新实例（例如从 Xcode 重新运行的版本）接替旧实例。
    private func quitOtherInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where other != NSRunningApplication.current {
            Log.app.notice("退出旧实例 pid=\(other.processIdentifier)")
            other.terminate()
        }
    }

    // MARK: - 微信进程

    private func startTracking() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        if let wechat = NSRunningApplication.runningApplications(withBundleIdentifier: WeChat.bundleIdentifier).first {
            attach(to: wechat.processIdentifier)
        } else {
            Log.tracking.notice("微信未运行")
        }

        let driver = RefreshDriver { [weak self] in self?.refresh() }
        driver.start()
        refreshDriver = driver
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == WeChat.bundleIdentifier else { return }
        attach(to: app.processIdentifier)
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == tracker?.pid else { return }
        Log.tracking.notice("微信已退出")
        detach()
    }

    private func attach(to pid: pid_t) {
        detach()
        let tracker = WeChatWindowTracker(pid: pid)
        tracker.onChange = { [weak self] in self?.refresh() }
        tracker.start()
        self.tracker = tracker
        Log.tracking.notice("开始跟踪微信 pid=\(pid)")
        refresh()
    }

    private func detach() {
        guard let tracker else { return }
        tracker.stop()
        self.tracker = nil
        refresh()
    }

    private func refresh() {
        let snapshot = tracker?.snapshot()
        if lockState.autoLockIfNeeded(for: snapshot) {
            Log.app.notice("微信主窗口已关闭，自动锁定")
            applyLockState()
        }
        maskController.update(snapshot: snapshot)
    }

    // MARK: - 锁定

    private func attemptUnlock(with password: String) -> Bool {
        guard PasswordVerifier.verify(password, against: config.password) else {
            Log.app.notice("解锁失败：密码错误")
            return false
        }
        lockState.unlock()
        Log.app.notice("已解锁")
        applyLockState()
        return true
    }

    private func applyLockState() {
        maskController.isLocked = lockState.isLocked
        statusMenu?.updateIcon()
    }

    // MARK: - 配置

    private func loadConfig() -> AppConfig {
        do {
            return try configStore.load()
        } catch {
            // 配置损坏不能让遮罩失效：用默认配置继续运行，下次保存时覆盖
            Log.app.error("配置读取失败，改用默认配置：\(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    private func saveListColumn(_ layout: ListColumnLayout) {
        config.listColumn = layout
        do {
            try configStore.save(config)
            Log.app.notice("已保存列表栏布局 left=\(layout.leftInset) top=\(layout.topInset) width=\(layout.width)")
        } catch {
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveHidePasswordInput(_ hidden: Bool) {
        config.hidePasswordInput = hidden
        do {
            try configStore.save(config)
        } catch {
            // 只是显示偏好：保存失败本次仍然生效，下次启动回到原来的选择
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 保存新的密码记录（nil 表示恢复默认密码）。写入成功才生效，避免"这次能用、重启后又变回旧密码"。
    private func savePassword(_ record: PasswordRecord?) -> Bool {
        var updated = config
        updated.password = record
        do {
            try configStore.save(updated)
            config = updated
            return true
        } catch {
            Log.app.error("密码保存失败：\(error.localizedDescription, privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "密码没有保存成功，仍使用原来的密码"
            alert.runModal()
            return false
        }
    }
}

// MARK: - 菜单栏

extension AppDelegate: StatusMenuDelegate {
    var statusDescription: String {
        guard permission.isGranted else { return "需要辅助功能权限" }
        if maskController.mode == .calibrating { return "正在校准遮罩位置" }
        guard lockState.isLocked else { return "已解锁" }
        guard tracker != nil else { return "已锁定 · 微信未运行" }
        return maskController.isShowing ? "已锁定 · 在遮罩上输入密码解锁" : "已锁定 · 微信窗口未显示"
    }

    var needsAccessibilityPermission: Bool { !permission.isGranted }

    var isLocked: Bool { lockState.isLocked }

    var canCalibrate: Bool { maskController.canCalibrate }

    func requestAccessibilityPermission() {
        permission.request()
        permission.openSystemSettings()
    }

    func lockNow() {
        lockState.lock()
        Log.app.notice("手动锁定")
        applyLockState()
    }

    func changePassword() {
        guard !lockState.isLocked, let newPassword = PasswordChangeDialog.run() else { return }
        guard let record = PasswordVerifier.makeRecord(for: newPassword) else {
            Log.app.error("生成密码记录失败")
            return
        }
        if savePassword(record) {
            Log.app.notice("已修改解锁密码")
        }
    }

    /// 锁定时也能用：只把密码改回默认值，不解锁也不锁定。
    func resetPassword() {
        let alert = NSAlert()
        alert.messageText = "是否恢复默认密码：\(PasswordVerifier.defaultPassword)"
        alert.addButton(withTitle: "恢复默认密码")
        alert.addButton(withTitle: "取消")
        // 菜单栏应用平时不在前台，先激活，对话框才会出现在最前面
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if savePassword(nil) {
            Log.app.notice("已恢复默认密码")
        }
    }

    func beginCalibration() {
        maskController.beginCalibration()
    }
}
