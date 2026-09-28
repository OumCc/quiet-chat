// 辅助功能权限：识别微信主窗口、监听窗口事件都依赖它。
// 权限只能由用户在「系统设置 → 隐私与安全性 → 辅助功能」中打开；这里只负责检测、弹出系统提示、打开设置页和等待授权。

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityPermission: NSObject {
    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?

    var isGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示，并把本应用加入「辅助功能」列表；系统只在第一次调用时弹窗。
    func request() {
        // 直接写键名：kAXTrustedCheckOptionPrompt 在 Swift 6 下是非并发安全的全局变量
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统设置中的「辅助功能」页面。
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 每秒检查一次授权状态；授权后回调一次并停止检查。
    func waitForGrant(_ onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(checkGrant), userInfo: nil, repeats: true)
    }

    @objc private func checkGrant() {
        guard isGranted else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        let callback = onGranted
        onGranted = nil
        callback?()
    }
}
