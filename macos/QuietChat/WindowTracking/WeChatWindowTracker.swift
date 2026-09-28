// 跟踪一个微信进程的聊天主窗口。
// 职责：用辅助功能接口识别主窗口并监听事件（移动、缩放、最小化、销毁、应用隐藏/激活），事件到来时回调 onChange；
// 位置、是否在屏、上方的遮挡窗口等实时数据由 snapshot() 从窗口服务器读取。
// 不变量：start() 与 stop() 成对调用，stop() 之前不得释放本对象——AXObserver 回调持有它的非保留指针。

import AppKit
import ApplicationServices
import QuietChatCore

/// 微信 macOS 版的固定标识。
enum WeChat {
    static let bundleIdentifier = "com.tencent.xinWeChat"
}

@MainActor
final class WeChatWindowTracker {
    let pid: pid_t
    /// 主窗口可能发生变化时回调（移动、缩放、显示状态变化等）。
    var onChange: (() -> Void)?

    // 微信无响应时，辅助功能调用最多等这么久（系统默认约 6 秒，会卡住主线程）；超时只对设置过的元素生效
    private static let messagingTimeout: Float = 0.3

    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var applicationNotificationsRegistered = false
    private var mainWindow: AXUIElement?
    private var mainWindowID: CGWindowID?
    private var lastResolveAttempt = Date.distantPast

    var hasMainWindow: Bool { mainWindowID != nil }

    init(pid: pid_t) {
        self.pid = pid
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
    }

    func start() {
        var created: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WeChatWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            // 观察者的运行循环源挂在主线程上，回调一定在主线程执行
            MainActor.assumeIsolated {
                tracker.handle(notification: name, element: element)
            }
        }, &created)
        guard error == .success, let created else {
            Log.tracking.error("AXObserverCreate 失败：\(error.rawValue)")
            return
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        resolveMainWindow()
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        mainWindow = nil
        mainWindowID = nil
    }

    /// 读取主窗口当前状态；没有可跟踪的主窗口时返回 nil。
    func snapshot() -> WindowSnapshot? {
        // 刷新可能每帧都来，这里限制重新识别的频率，避免频繁跨进程调用
        if mainWindowID == nil || !applicationNotificationsRegistered,
           Date().timeIntervalSince(lastResolveAttempt) > 0.5 {
            resolveMainWindow()
        }
        guard let windowID = mainWindowID else { return nil }
        guard let info = WindowServer.info(of: windowID) else {
            Log.tracking.notice("主窗口 \(windowID) 已不存在")
            forgetMainWindow()
            return nil
        }
        guard info.isOnScreen else {
            return WindowSnapshot(frame: info.frame, isOnScreen: false, isExplicitlyHidden: isExplicitlyHidden)
        }
        let occluders = WindowServer.occluders(
            above: windowID, excludingPIDs: [pid, ProcessInfo.processInfo.processIdentifier])
        return WindowSnapshot(frame: info.frame, isOnScreen: true, occluders: occluders)
    }

    /// 最小化或微信被隐藏：可以确定主窗口不在任何桌面上显示。
    private var isExplicitlyHidden: Bool {
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return true }
        return mainWindow?.bool(kAXMinimizedAttribute) == true
    }

    private func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXUIElementDestroyedNotification:
            if let mainWindow, CFEqual(mainWindow, element) {
                Log.tracking.notice("主窗口已销毁")
                forgetMainWindow()
            }
            resolveMainWindow()
        case kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            resolveMainWindow()
        default:
            break
        }
        onChange?()
    }

    /// 重新识别主窗口；结果与当前主窗口不同时，改为监听新窗口。
    private func resolveMainWindow() {
        lastResolveAttempt = Date()
        registerApplicationNotificationsIfNeeded()
        let windows = appElement.windows
        for window in windows {
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        }
        let candidates = windows.map {
            WindowCandidate(title: $0.string(kAXTitleAttribute), subrole: $0.string(kAXSubroleAttribute), size: $0.size ?? .zero)
        }
        // 找不到时保留原主窗口：主窗口被关闭后可能暂时不在辅助功能列表里，但窗口服务器仍能查到它
        guard let index = MainWindowSelector.selectMainWindow(from: candidates) else { return }
        let window = windows[index]
        if let mainWindow, CFEqual(mainWindow, window) {
            if mainWindowID == nil { mainWindowID = windowID(of: window) }
            return
        }

        forgetMainWindow()
        mainWindow = window
        mainWindowID = windowID(of: window)
        for name in Self.windowNotifications {
            register(name, on: window)
        }
        let size = candidates[index].size
        Log.tracking.notice(
            "识别到主窗口 id=\(self.mainWindowID ?? 0) 尺寸=\(Int(size.width))x\(Int(size.height))，微信共 \(windows.count) 个辅助功能窗口")
    }

    private func forgetMainWindow() {
        if let observer, let mainWindow {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, mainWindow, name as CFString)
            }
        }
        mainWindow = nil
        mainWindowID = nil
    }

    private func windowID(of window: AXUIElement) -> CGWindowID? {
        window.windowID ?? window.frame.flatMap { WindowServer.windowID(ownedBy: pid, matching: $0) }
    }

    /// 微信刚启动时可能还没准备好辅助功能服务，注册会失败；失败后在下次识别主窗口时重试。
    private func registerApplicationNotificationsIfNeeded() {
        guard !applicationNotificationsRegistered, observer != nil else { return }
        applicationNotificationsRegistered = Self.applicationNotifications.allSatisfy { register($0, on: appElement) }
    }

    /// 注册一个事件；成功或此前已注册时返回 true。
    @discardableResult
    private func register(_ notification: String, on element: AXUIElement) -> Bool {
        guard let observer else { return false }
        let error = AXObserverAddNotification(
            observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        guard error == .success || error == .notificationAlreadyRegistered else {
            Log.tracking.notice("注册 \(notification, privacy: .public) 失败：\(error.rawValue)")
            return false
        }
        return true
    }

    private static let applicationNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
        kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
    ]

    // 移动 / 缩放事件只在操作结束时发送，拖动过程中的位置由 RefreshDriver 逐帧读取
    private static let windowNotifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
    ]
}
