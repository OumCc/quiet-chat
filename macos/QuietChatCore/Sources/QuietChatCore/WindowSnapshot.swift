// 窗口跟踪模块交给遮罩、锁定模块的数据：微信主窗口在某一时刻的状态。
// 这是模块之间的数据契约；Windows 端用同样的字段语义实现。

import CoreGraphics

/// 主窗口相对于当前桌面的状态。
public enum WindowPresence: Equatable, Sendable {
    /// 显示在当前桌面上。
    case visible
    /// 仍然开着，但在另一个桌面上（用户切换了桌面）。
    case onOtherSpace
    /// 已关闭、最小化，或微信被隐藏：不在任何桌面上显示。
    case closed

    /// 由窗口服务器提供的信息判断窗口状态。
    ///
    /// 关闭的窗口不属于任何桌面，在其他桌面上的窗口仍然属于那个桌面，靠这一点区分两者。
    /// 取不到桌面信息时按"已关闭"处理：宁可多锁一次，也不把关掉的窗口当成还开着。
    /// - Parameters:
    ///   - isOnScreen: 窗口服务器报告窗口在当前桌面上可见。
    ///   - isExplicitlyHidden: 已确认窗口最小化，或应用被隐藏。
    ///   - spaceCount: 窗口所属的桌面数；取不到时为 nil。
    public static func classify(isOnScreen: Bool, isExplicitlyHidden: Bool, spaceCount: Int?) -> WindowPresence {
        if isOnScreen { return .visible }
        if isExplicitlyHidden { return .closed }
        guard let spaceCount, spaceCount > 0 else { return .closed }
        return .onOtherSpace
    }
}

/// 微信主窗口在某一时刻的状态，坐标为 Quartz 全局坐标。
public struct WindowSnapshot: Equatable, Sendable {
    /// 窗口外框。
    public var frame: CGRect
    public var presence: WindowPresence
    /// 窗口是否被分配到所有桌面（例如在程序坞中把微信设为"分配给：所有桌面"）。
    /// 这时遮罩也要出现在所有桌面，否则切换桌面后微信还在、遮罩却留在了原来的桌面。
    public var isOnAllSpaces: Bool
    /// 压在窗口之上、会挡住它的其他窗口外框。
    public var occluders: [CGRect]

    public init(frame: CGRect, presence: WindowPresence, isOnAllSpaces: Bool = false, occluders: [CGRect] = []) {
        self.frame = frame
        self.presence = presence
        self.isOnAllSpaces = isOnAllSpaces
        self.occluders = occluders
    }
}
