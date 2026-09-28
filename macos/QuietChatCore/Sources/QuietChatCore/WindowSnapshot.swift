// 窗口跟踪模块交给遮罩模块的数据：微信主窗口在某一时刻的状态。
// 这是两个模块之间唯一的数据契约；Windows 端用同样的字段语义实现。

import CoreGraphics

/// 微信主窗口在某一时刻的状态，坐标为 Quartz 全局坐标。
public struct WindowSnapshot: Equatable, Sendable {
    /// 窗口外框。
    public var frame: CGRect
    /// 窗口是否显示在当前桌面上；最小化、隐藏、关闭或位于其他桌面时为 false。
    public var isOnScreen: Bool
    /// 是否可以确定窗口不在任何桌面上显示（最小化、应用被隐藏）。
    /// 用来区分"窗口没了"和"窗口在另一个桌面上"，两者在窗口服务器里都表现为不在屏上。
    public var isExplicitlyHidden: Bool
    /// 压在窗口之上、会挡住它的其他窗口外框。
    public var occluders: [CGRect]

    public init(frame: CGRect, isOnScreen: Bool, isExplicitlyHidden: Bool = false, occluders: [CGRect] = []) {
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.isExplicitlyHidden = isExplicitlyHidden
        self.occluders = occluders
    }
}
