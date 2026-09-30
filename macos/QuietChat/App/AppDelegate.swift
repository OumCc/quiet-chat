// 应用装配：加载配置、处理辅助功能授权、随微信进程启动/退出创建或销毁窗口跟踪器，
// 在任何可能改变遮罩位置或可见性的时刻刷新遮罩（刷新时机见 docs/architecture.md「刷新时机」），
// 并维护锁定状态：密码解锁、主窗口关闭时自动锁定（见「锁定与解锁」）。
// 遮挡方式（整块 / 精准）只决定锁定时遮住哪里：精准遮挡下把 PreciseRevealController 给出的带区交给遮罩开洞（见「精准遮挡」）。

import AppKit
import QuietChatCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore(fileURL: ConfigStore.defaultFileURL)
    private var config = AppConfig.default
    private var lockState = LockState()
    private let permission = AccessibilityPermission()
    private let maskController = MaskController()
    private let preciseReveal = PreciseRevealController()
    private let whitelistEditor = WhitelistEditorController()
    private var statusMenu: StatusMenuController?
    private var refreshDriver: RefreshDriver?
    private var tracker: WeChatWindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherInstances()
        config = loadConfig()
        applyMaskMode()
        preciseReveal.onChange = { [weak self] in
            guard let self else { return }
            self.maskController.revealedBands = self.preciseReveal.revealedBands
        }
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
        // 先让精准遮挡按最新状态决定露出哪些行，再画遮罩：条件不满足时这一次刷新就会全部盖住
        preciseReveal.update(
            mode: config.maskMode, isLocked: lockState.isLocked, snapshot: snapshot, windowID: tracker?.mainWindowID,
            layout: config.listColumnLayout(for: .precise), whitelist: config.whitelist)
        maskController.revealedBands = preciseReveal.revealedBands
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
        refresh()
        return true
    }

    /// 把锁定状态落实到遮罩和菜单栏图标。精准遮挡要不要读取画面由随后的 refresh() 决定。
    private func applyLockState() {
        maskController.isLocked = lockState.isLocked
        statusMenu?.updateIcon()
        // 编辑白名单等于放开对应的聊天，锁定后不能继续；未保存的修改丢弃
        if lockState.isLocked {
            whitelistEditor.close()
        }
    }

    // MARK: - 遮挡方式

    /// 按当前遮挡方式设置遮罩：用哪一套布局、密码框放在哪里、底部留不留一条。
    private func applyMaskMode() {
        let isPrecise = config.maskMode == .precise
        maskController.layout = config.listColumnLayout(for: config.maskMode)
        maskController.reservedBottomHeight = isPrecise ? MaskPlanner.preciseReservedBottomHeight : 0
        maskController.lockControlsPlacement =
            isPrecise ? .bottomStrip(height: MaskPlanner.preciseReservedBottomHeight) : .centered
    }

    private func saveWhitelist(_ whitelist: [String]) {
        config.whitelist = whitelist
        do {
            try configStore.save(config)
            // 名称不写入日志
            Log.app.notice("已保存白名单：\(whitelist.count) 个名称")
        } catch {
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
        refresh()
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

    /// 保存校准结果。两种遮挡方式各有一套布局，校准只改当前方式的那一套。
    private func saveListColumn(_ layout: ListColumnLayout) {
        switch config.maskMode {
        case .full:
            config.listColumn = layout
        case .precise:
            config.preciseListColumn = layout
        }
        do {
            try configStore.save(config)
            Log.app.notice(
                "已保存列表栏布局（\(self.config.maskMode.rawValue, privacy: .public)）left=\(layout.leftInset) top=\(layout.topInset) width=\(layout.width)")
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
        if needsScreenRecordingPermission { return "精准遮挡需要屏幕录制权限" }
        if maskController.mode == .calibrating { return "正在校准遮罩位置" }
        guard lockState.isLocked else { return "已解锁" }
        if config.maskMode == .precise { return "已锁定 · 精准遮挡" }
        guard tracker != nil else { return "已锁定 · 微信未运行" }
        return maskController.isShowing ? "已锁定 · 在遮罩上输入密码解锁" : "已锁定 · 微信窗口未显示"
    }

    var needsAccessibilityPermission: Bool { !permission.isGranted }

    var isLocked: Bool { lockState.isLocked }

    var canCalibrate: Bool { maskController.canCalibrate }

    var maskMode: MaskMode { config.maskMode }

    var canEditWhitelist: Bool { config.maskMode == .precise && !lockState.isLocked }

    /// 权限被收回、或系统要求重新确认时，系统查询可能仍然返回"已授权"，所以读取画面失败也算。
    var needsScreenRecordingPermission: Bool {
        config.maskMode == .precise && (!ScreenRecordingPermission.isGranted || preciseReveal.isCaptureFailing)
    }

    /// 以系统登录项为准，不写入配置：用户也可能在「系统设置 → 通用 → 登录项」里直接增删，
    /// 菜单每次打开都重新读取，两边不会不一致。系统默认没有登记，即默认关闭。
    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func requestAccessibilityPermission() {
        permission.request()
        permission.openSystemSettings()
    }

    func requestScreenRecordingPermission() {
        ScreenRecordingPermission.request()
        ScreenRecordingPermission.openSystemSettings()
        preciseReveal.recheckPermission()
    }

    func lockNow() {
        lockState.lock()
        Log.app.notice("手动锁定")
        applyLockState()
        refresh()
    }

    /// 锁定时也能切换：遮挡方式只决定遮住哪里，不改变锁定状态。
    func selectMaskMode(_ mode: MaskMode) {
        guard mode != config.maskMode else { return }
        config.maskMode = mode
        do {
            try configStore.save(config)
            Log.app.notice("遮挡方式：\(mode.rawValue, privacy: .public)")
        } catch {
            // 本次仍然生效，下次启动回到原来的方式
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
        maskController.cancelCalibration()
        applyMaskMode()
        switch mode {
        case .precise:
            // 屏幕录制权限只在这里申请；使用整块遮挡时从不申请
            if !ScreenRecordingPermission.isGranted {
                ScreenRecordingPermission.request()
            }
            preciseReveal.recheckPermission()
            if config.whitelist.isEmpty {
                editWhitelist()
            }
        case .full:
            whitelistEditor.close()
        }
        refresh()
    }

    func editWhitelist() {
        guard canEditWhitelist else { return }
        whitelistEditor.show(whitelist: config.whitelist) { [weak self] whitelist in
            self?.saveWhitelist(whitelist)
        }
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

    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        let enable = service.status != .enabled
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.app.notice("开机自启动：\(enable ? "开启" : "关闭", privacy: .public)")
        } catch {
            Log.app.error("开机自启动设置失败：\(error.localizedDescription, privacy: .public)")
            showLoginItemsAlert("开机自启动没有设置成功", detail: error.localizedDescription)
            return
        }
        // 用户在系统设置里关掉过本应用时，登记成功后仍要用户到设置里重新允许
        if service.status == .requiresApproval {
            showLoginItemsAlert("需要在系统设置里允许 QuietChat 开机自启动")
        }
    }

    /// 开机自启动需要用户处理时提示，并提供跳到「登录项」设置页的入口。
    private func showLoginItemsAlert(_ message: String, detail: String? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = [detail, "可以在「系统设置 → 通用 → 登录项」里查看和修改。"]
            .compactMap { $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "打开登录项设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
