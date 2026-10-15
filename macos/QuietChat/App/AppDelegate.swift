// 应用装配：加载配置、处理辅助功能授权、随微信进程启动/退出创建或销毁窗口跟踪器，
// 在任何可能改变遮罩位置或可见性的时刻刷新遮罩（刷新时机见 docs/architecture.md「刷新时机」），
// 并维护锁定状态：密码解锁、主窗口关闭时自动锁定（见「锁定与解锁」）。
// 快捷入口由用户点击发起一次键盘搜索；显示刷新不发按键，模式和目标失效时取消。
// 分阶段响应速度随配置保存；变更先取消旧操作，点击时传入不可变快照。
// 外观由应用统一设置，窗口和控件继承；切换时保留输入与校准草稿。
// 更新检查须先取得同意；升级后按实际权限显示一次重新授权引导。
// 定时强控与锁定/遮挡方式独立，运行期截止时间不落盘；设置成功保存后才应用。

import AppKit
import QuietChatCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore(fileURL: ConfigStore.defaultFileURL)
    private var config = AppConfig.default
    private var lockState = LockState()
    private var timedControl = TimedControlState()
    private var timedControlTimer: Timer?
    private let permission = AccessibilityPermission()
    private let updatePreferences = UpdatePreferences()
    private var updates: AppUpdateController?
    private let maskController = MaskController()
    private let shortcuts = WeChatShortcutController()
    private var lastMainWindowID: CGWindowID?
    private let whitelistEditor = WhitelistEditorController()
    private var statusMenu: StatusMenuController?
    private var refreshDriver: RefreshDriver?
    private var tracker: WeChatWindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherInstances()
        config = loadConfig()
        applyAppearanceMode()
        applyMaskMode()
        shortcuts.onChange = { [weak self] in
            guard let self else { return }
            self.maskController.updateShortcutFeedback(isBusy: self.shortcuts.isBusy, message: self.shortcuts.message)
        }
        maskController.onShortcut = { [weak self] name in self?.openShortcut(name) }
        maskController.onPasswordFocus = { [weak self] in
            guard let self, self.shortcuts.isBusy else { return }
            self.shortcuts.cancel(showFeedback: true)
        }
        maskController.onCalibrationFinished = { [weak self] layout in self?.saveListColumn(layout) }
        maskController.onUnlockAttempt = { [weak self] password, requirement in
            self?.attemptUnlock(with: password, requirement: requirement) ?? .incorrect
        }
        maskController.hidesPasswordInput = config.hidePasswordInput
        maskController.onPasswordVisibilityChange = { [weak self] hidden in self?.saveHidePasswordInput(hidden) }
        syncTimedControl()
        statusMenu = StatusMenuController(delegate: self)

        let updates = AppUpdateController(preferences: updatePreferences)
        updates.onChange = { [weak self] in self?.statusMenu?.updateIcon() }
        updates.onUserInteraction = { [weak self] in self?.prepareToOpenStatusMenu() }
        updates.onRelaunch = { [weak self] in self?.shortcuts.cancel() }
        self.updates = updates
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let needsUpgradeReminder = UpdatePreferences.needsPermissionReminder(
            buildChanged: updatePreferences.recordLaunch(buildVersion: build),
            hasAccessibility: permission.isGranted,
            needsKeyboardAccess: config.maskMode == .shortcuts, canPostEvents: permission.canPostEvents)

        if permission.isGranted {
            startTracking()
        } else {
            Log.app.notice("辅助功能未授权，等待用户授权")
            if !needsUpgradeReminder { permission.request() }
            permission.waitForGrant { [weak self] in
                Log.app.notice("辅助功能已授权")
                self?.startTracking()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if needsUpgradeReminder { self.showUpgradePermissionReminder() }
            self.updates?.start()
        }
    }

    private func showUpgradePermissionReminder() {
        let alert = NSAlert()
        alert.messageText = "升级后需要重新授权"
        alert.informativeText = "QuietChat 使用临时签名，升级后系统可能不再认可旧的辅助功能授权。请在“隐私与安全性 → 辅助功能”用“−”移除旧的 QuietChat，再用“+”添加当前应用并开启权限。快捷入口也需要键盘合成访问。你的密码、白名单和校准设置仍然保留。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { requestAccessibilityPermission() }
    }

    /** 退出时使旧操作失效，再释放窗口和刷新监听。 */
    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.cancel()
        tracker?.stop()
        refreshDriver?.stop()
        timedControlTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func openShortcut(_ name: String) {
        guard config.maskMode == .shortcuts, lockState.isLocked, maskController.mode == .masking,
              ChatWhitelist.normalized(config.whitelist).contains(name) else { return }
        guard let tracker, let target = tracker.shortcutTarget() else {
            shortcuts.reportUnavailableTarget()
            return
        }
        shortcuts.start(name: name, timing: config.shortcutTiming, tracker: tracker, target: target,
                        releaseFocus: { [weak self] in self?.maskController.releaseInputFocus() },
                        isAllowed: { [weak self, weak tracker] in
            guard let self, let tracker else { return false }
            return self.config.maskMode == .shortcuts && self.lockState.isLocked
                && self.maskController.mode == .masking && self.maskController.isShowing
                && self.tracker === tracker && tracker.shortcutTarget() == target
                && ChatWhitelist.normalized(self.config.whitelist).contains(name)
        })
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
        shortcuts.cancel()
        lastMainWindowID = nil
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
        if lastMainWindowID != tracker?.mainWindowID {
            shortcuts.cancel()
            lastMainWindowID = tracker?.mainWindowID
        }
        if config.maskMode != .shortcuts || !lockState.isLocked || maskController.mode != .masking
            || snapshot?.presence != .visible {
            shortcuts.cancel()
        } else {
            shortcuts.cancelIfTargetInvalid()
        }
        maskController.update(snapshot: snapshot)
    }

    // MARK: - 锁定

    private func attemptUnlock(with password: String, requirement: UnlockRequirement) -> UnlockAttemptResult {
        guard lockState.isLocked else { return .requirementChanged }
        let result = timedControl.attemptUnlock(password, requirement: requirement, settings: config.timedControl,
                                               passwordRecord: config.password, at: .now)
        syncTimedControl()
        guard result == .unlocked else {
            if result == .incorrect { Log.app.notice("解锁失败：输入不匹配") }
            return result
        }
        lockState.unlock()
        Log.app.notice("已解锁")
        applyLockState()
        refresh()
        return .unlocked
    }

    /** 只同步强控展示与计时任务，不改变锁定、快捷任务或普通输入偏好。 */
    private func syncTimedControl() {
        let now = ContinuousClock.now
        timedControl.expireIfNeeded(at: now)
        let seconds = timedControl.remainingSeconds(at: now)
        maskController.updateTimedControl(requirement: timedControl.requirement(at: now), remainingSeconds: seconds)
        if seconds > 0, timedControlTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(timedControlTick), userInfo: nil, repeats: true)
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            timedControlTimer = timer
        } else if seconds == 0 {
            timedControlTimer?.invalidate()
            timedControlTimer = nil
        }
    }

    @objc private func timedControlTick() { syncTimedControl() }

    /** 落实锁定状态；解锁取消按键任务，重新锁定继续沿用当前方式。 */
    private func applyLockState() {
        shortcuts.cancel()
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
        shortcuts.cancel()
        maskController.layout = config.listColumnLayout(for: config.maskMode)
        maskController.usesShortcuts = config.maskMode == .shortcuts
        maskController.shortcutNames = ChatWhitelist.normalized(config.whitelist)
        maskController.lockControlsPlacement = config.maskMode == .shortcuts ? .bottomStrip(height: 56) : .centered
    }

    private func saveWhitelist(_ whitelist: [String]) {
        shortcuts.cancel()
        config.whitelist = whitelist
        maskController.shortcutNames = whitelist
        do {
            try configStore.save(config)
            // 名称不写入日志
            Log.app.notice("已保存白名单：\(whitelist.count) 个名称")
        } catch {
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    // MARK: - 外观

    /** 应用外观偏好；nil 让 AppKit 持续跟随系统变化，无需自行监听或保存当前系统颜色。 */
    private func applyAppearanceMode() {
        switch config.appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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
        case .shortcuts:
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
    /** 自己的菜单取得输入时也视为离开微信目标，立即使旧搜索失效。 */
    func prepareToOpenStatusMenu() {
        if shortcuts.isBusy { shortcuts.cancel(showFeedback: true) }
        syncTimedControl()
    }

    var statusDescription: String {
        guard permission.isGranted else { return "需要辅助功能权限" }
        if maskController.mode == .calibrating { return "正在校准遮罩位置" }
        guard lockState.isLocked else { return "已解锁" }
        guard tracker != nil else { return "已锁定 · 微信未运行" }
        if config.maskMode == .shortcuts, !permission.canPostEvents { return "已锁定 · 快捷入口需要键盘合成权限" }
        let visibleStatus = config.maskMode == .shortcuts ? "已锁定 · 白名单快捷入口" : "已锁定 · 在遮罩上输入密码解锁"
        return maskController.isShowing ? visibleStatus : "已锁定 · 微信窗口未显示"
    }

    var needsAccessibilityPermission: Bool { !permission.isGranted || (config.maskMode == .shortcuts && !permission.canPostEvents) }

    var isLocked: Bool { lockState.isLocked }

    var canCalibrate: Bool { maskController.canCalibrate }

    var maskMode: MaskMode { config.maskMode }

    /** 菜单按用户选择勾选，不将跟随系统解析为固定浅色或深色。 */
    var appearanceMode: AppearanceMode { config.appearanceMode }

    /** 当前分阶段响应速度；菜单显示保存选择，搜索开始时再捕获快照。 */
    var shortcutTiming: ShortcutTiming { config.shortcutTiming }

    var timedControlSettings: TimedControlSettings { config.timedControl }
    var timedControlRemainingSeconds: Int { timedControl.remainingSeconds(at: .now) }

    /** 活动周期先独立手输确认，再原子保存；取消和失败不改变偏好、截止时间或锁定状态。 */
    func selectTimedControl(_ settings: TimedControlSettings) {
        let previous = config.timedControl
        guard settings != previous else { return }
        shortcuts.cancel()
        if timedControl.requirement(at: .now) == .keyboardSequence {
            let action = settings.enabled ? "将定时强控改为 \(settings.durationMinutes) 分钟" : "关闭定时强控"
            guard KeyboardSequenceDialog.run(action: action, isRequired: { [self] in
                timedControl.requirement(at: .now) == .keyboardSequence
            }) else { return }
        }
        var updated = config
        updated.timedControl = settings
        do {
            try configStore.save(updated)
            config = updated
            timedControl.applySettings(settings, replacing: previous, at: .now)
            syncTimedControl()
        } catch {
            Log.app.error("定时强控设置保存失败：\(error.localizedDescription, privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "定时强控设置没有保存成功，仍使用原来的设置"
            NSApp.activate()
            alert.runModal()
        }
    }

    var canEditWhitelist: Bool { config.maskMode == .shortcuts && !lockState.isLocked }

    var canCheckForUpdates: Bool { updates?.canCheckForUpdates ?? false }
    var automaticallyChecksForUpdates: Bool { updates?.automaticallyChecksForUpdates ?? false }
    var availableUpdateVersion: String? { updates?.availableUpdateVersion }

    func checkForUpdates() { updates?.checkForUpdates() }
    func toggleAutomaticUpdateChecks() { updates?.toggleAutomaticChecks() }
    func openUpdateDownloads() { updates?.openDownloads() }

    /// 以系统登录项为准，不写入配置：用户也可能在「系统设置 → 通用 → 登录项」里直接增删，
    /// 菜单每次打开都重新读取，两边不会不一致。系统默认没有登记，即默认关闭。
    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func requestAccessibilityPermission() {
        if config.maskMode == .shortcuts { permission.requestShortcutAccess() }
        else { permission.request() }
        permission.openSystemSettings()
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
        shortcuts.cancel()
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
        case .shortcuts:
            if config.whitelist.isEmpty {
                editWhitelist()
            }
        case .full:
            whitelistEditor.close()
        }
        refresh()
    }

    /** 切换并保存整个应用的外观；保存失败时本次仍生效，不改变锁定状态或当前编辑内容。 */
    func selectAppearanceMode(_ mode: AppearanceMode) {
        guard mode != config.appearanceMode else { return }
        config.appearanceMode = mode
        applyAppearanceMode()
        do {
            try configStore.save(config)
            Log.app.notice("外观：\(mode.rawValue, privacy: .public)")
        } catch {
            // 显示偏好保存失败时本次仍生效，下次启动读取最后成功保存的配置
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /** 只在快捷入口方式修改并保存时序；先取消旧搜索，保存失败时本次仍生效。 */
    func selectShortcutTiming(_ timing: ShortcutTiming) {
        guard config.maskMode == .shortcuts, timing != config.shortcutTiming else { return }
        shortcuts.cancel()
        config.shortcutTiming = timing
        do {
            try configStore.save(config)
        } catch {
            Log.app.error("快捷入口时序保存失败：\(error.localizedDescription, privacy: .public)")
        }
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
        shortcuts.cancel()
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
