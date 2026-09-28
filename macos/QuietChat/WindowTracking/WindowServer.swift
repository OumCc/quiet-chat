// 窗口服务器（CGWindowList）查询：无需任何权限即可读取窗口外框、层级、是否在屏（读不到标题）。
// 与辅助功能接口不同，它不经过微信进程，窗口被拖动的过程中也能拿到实时位置，适合高频读取。

import CoreGraphics
import Foundation

enum WindowServer {
    struct WindowInfo: Equatable {
        /// Quartz 全局坐标。
        var frame: CGRect
        /// 是否显示在当前桌面上；最小化、隐藏、关闭或位于其他桌面时为 false。
        var isOnScreen: Bool
    }

    /// 读取单个窗口；窗口已不存在时返回 nil。
    static func info(of windowID: CGWindowID) -> WindowInfo? {
        guard let entry = windowList([.optionIncludingWindow], relativeTo: windowID).first(where: { number(of: $0) == windowID }),
              let frame = bounds(of: entry) else { return nil }
        return WindowInfo(frame: frame, isOnScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    /// 压在指定窗口之上、会挡住它的窗口外框（Quartz 全局坐标）。
    ///
    /// 只统计普通层级（layer 0）且可见的窗口；`excludedPIDs` 中进程的窗口不计入。
    /// 调用方会排除本应用和微信自身：微信有不少不可见的辅助窗口，把它们当成遮挡会在遮罩上误开洞。
    static func occluders(above windowID: CGWindowID, excludingPIDs excludedPIDs: Set<pid_t>) -> [CGRect] {
        windowList([.optionOnScreenAboveWindow, .excludeDesktopElements], relativeTo: windowID).compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, !excludedPIDs.contains(pid),
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
                  let frame = bounds(of: entry), frame.width > 1, frame.height > 1 else { return nil }
            return frame
        }
    }

    /// 在指定进程的普通层级窗口中按外框查找窗口编号；私有接口取不到编号时兜底使用。
    static func windowID(ownedBy pid: pid_t, matching frame: CGRect) -> CGWindowID? {
        windowList([.optionAll], relativeTo: kCGNullWindowID).first { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (entry[kCGWindowLayer as String] as? Int) == 0
                && bounds(of: entry) == frame
        }.flatMap(number(of:))
    }

    private static func windowList(_ options: CGWindowListOption, relativeTo windowID: CGWindowID) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]]) ?? []
    }

    private static func number(of entry: [String: Any]) -> CGWindowID? {
        (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    private static func bounds(of entry: [String: Any]) -> CGRect? {
        guard let dictionary = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
