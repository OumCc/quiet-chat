// 全局屏幕坐标换算。
// 窗口服务器（CGWindowList）和辅助功能接口使用 Quartz 坐标：原点在主显示器左上角，y 向下；
// AppKit 窗口使用 Cocoa 坐标：原点在主显示器左下角，y 向上。两者互为以主显示器高度为轴的翻转。

import CoreGraphics

/// Quartz 与 Cocoa 全局坐标之间的换算。
public enum GlobalCoordinates {
    /// 在 Quartz 与 Cocoa 全局坐标之间转换矩形，同一公式双向适用。
    /// - Parameter primaryScreenHeight: 主显示器（坐标原点所在的屏幕）的高度，单位 pt。
    public static func flip(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
