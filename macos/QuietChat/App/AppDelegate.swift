// 应用装配：加载配置、处理辅助功能授权、随微信进程启动/退出创建或销毁窗口跟踪器，
// 并在任何可能改变遮罩位置或可见性的时刻刷新遮罩（刷新时机见 docs/architecture.md「刷新时机」）。

import AppKit
import QuietChatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore(fileURL: ConfigStore.defaultFileURL)
    private var config = AppConfig.default
    private let permission = AccessibilityPermission()
    private let maskController = MaskController()
    private var statusMenu: StatusMenuController?
    private var refreshDriver: RefreshDriver?
    private var tracker: WeChatWindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = loadConfig()
        maskController.layout = config.listColumn
        maskController.onCalibrationFinished = { [weak self] layout in self?.saveListColumn(layout) }
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
        maskController.update(snapshot: tracker?.snapshot())
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
}

// MARK: - 菜单栏

extension AppDelegate: StatusMenuDelegate {
    var statusDescription: String {
        guard permission.isGranted else { return "需要辅助功能权限" }
        guard let tracker else { return "微信未运行" }
        guard tracker.hasMainWindow else { return "未找到微信主窗口" }
        if maskController.mode == .calibrating { return "正在校准遮罩位置" }
        guard maskController.isEnabled else { return "遮罩已关闭" }
        return maskController.isShowing ? "遮罩生效中" : "微信窗口未显示"
    }

    var needsAccessibilityPermission: Bool { !permission.isGranted }

    var isMaskEnabled: Bool { maskController.isEnabled }

    var canCalibrate: Bool { maskController.canCalibrate }

    func requestAccessibilityPermission() {
        permission.request()
        permission.openSystemSettings()
    }

    func toggleMask() {
        maskController.isEnabled.toggle()
        refresh()
    }

    func beginCalibration() {
        maskController.beginCalibration()
    }
}
