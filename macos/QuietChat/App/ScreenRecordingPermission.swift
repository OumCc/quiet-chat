// 屏幕录制权限：只有精准遮挡需要，用来读取微信窗口的画面、识别聊天列表里的名称。
// 权限只能由用户在「系统设置 → 隐私与安全性」中打开；这里只负责检测、弹出系统提示和打开设置页。
// 调用时机由 AppDelegate 决定：只在切换到精准遮挡或点击授权入口时申请，使用整块遮挡时从不申请。

import AppKit
import CoreGraphics

@MainActor
enum ScreenRecordingPermission {
    /// 是否已获得权限；只查询，不会弹出系统提示。
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 申请权限：系统只在第一次调用时弹出提示，并把本应用加入屏幕录制的列表。
    static func request() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// 打开系统设置中屏幕录制权限的页面。
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
