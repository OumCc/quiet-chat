// 刷新时机：把"可能改变遮罩位置或可见性"的系统事件汇总成一次 refresh 回调。
// - 事件：切换前台应用、切换桌面、应用隐藏/取消隐藏、显示器配置变化（微信窗口自身的事件由 WeChatWindowTracker 负责）；
// - 鼠标左键按下期间逐帧刷新：系统的窗口移动/缩放事件只在拖动结束时发出，拖动过程只能逐帧读取窗口服务器；
// - 兜底轮询：覆盖没有事件的变化，例如其他应用的窗口被快捷键移到微信上方。

import AppKit
import QuartzCore

@MainActor
final class RefreshDriver: NSObject {
    /// 松开鼠标后继续逐帧刷新的时长，覆盖窗口落定前的最后几帧。
    private static let trailingFrameRefresh: TimeInterval = 0.3
    private static let fallbackInterval: TimeInterval = 0.25

    private let refresh: () -> Void
    private var mouseMonitor: Any?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var stopFrameRefreshTimer: Timer?

    init(refresh: @escaping () -> Void) {
        self.refresh = refresh
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ] {
            workspace.addObserver(self, selector: #selector(fire), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(fire), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let isMouseDown = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                if isMouseDown {
                    self?.beginFrameRefresh()
                } else {
                    self?.scheduleEndOfFrameRefresh()
                }
            }
        }

        let timer = Timer.scheduledTimer(
            timeInterval: Self.fallbackInterval, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
        timer.tolerance = 0.05
        fallbackTimer = timer
    }

    @objc private func fire() {
        refresh()
    }

    private func beginFrameRefresh() {
        stopFrameRefreshTimer?.invalidate()
        stopFrameRefreshTimer = nil
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func scheduleEndOfFrameRefresh() {
        stopFrameRefreshTimer?.invalidate()
        stopFrameRefreshTimer = Timer.scheduledTimer(
            timeInterval: Self.trailingFrameRefresh, target: self, selector: #selector(endFrameRefresh),
            userInfo: nil, repeats: false)
    }

    @objc private func endFrameRefresh() {
        displayLink?.invalidate()
        displayLink = nil
        stopFrameRefreshTimer = nil
        refresh()
    }
}
