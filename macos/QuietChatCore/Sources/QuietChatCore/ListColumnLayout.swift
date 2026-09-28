// 聊天列表栏在微信主窗口内的位置（校准结果），以及由它推导出的屏幕矩形。
// 约定：矩形均为 Quartz 全局坐标（左上原点、y 向下，单位 pt）；列表栏总是向下延伸到窗口底边。

import CoreGraphics

/// 聊天列表栏相对微信主窗口外框的位置，由用户校准得到。
///
/// 微信窗口左侧依次是图标栏和聊天列表栏，列表栏到窗口左边缘的距离不随窗口大小变化，
/// 所以用"左边距 + 上边距 + 宽度"描述，窗口移动或缩放后无需重新校准。
public struct ListColumnLayout: Codable, Equatable, Sendable {
    /// 列表栏左边缘到窗口左边缘的距离。
    public var leftInset: Double
    /// 列表栏上边缘到窗口上边缘的距离。
    public var topInset: Double
    /// 列表栏宽度。
    public var width: Double

    public init(leftInset: Double, topInset: Double, width: Double) {
        self.leftInset = leftInset
        self.topInset = topInset
        self.width = width
    }

    /// 未校准时使用的估计值，对应微信 4.x 的默认布局。
    public static let `default` = ListColumnLayout(leftInset: 64, topInset: 0, width: 280)

    /// 校准时允许的最小宽度和高度，防止把遮罩拖成一条线后无法再拖回来。
    public static let minimumLength: Double = 40

    /// 列表栏在屏幕上的矩形，已裁剪到窗口范围内；窗口太小、没有交集时返回 nil。
    public func rect(in windowFrame: CGRect) -> CGRect? {
        let column = CGRect(
            x: Double(windowFrame.minX) + leftInset,
            y: Double(windowFrame.minY) + topInset,
            width: width,
            height: Double(windowFrame.height) - topInset)
        let clipped = column.intersection(windowFrame)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// 由校准时拖出的屏幕矩形反推布局。
    ///
    /// 先把矩形限制在窗口内，再保证最小尺寸；矩形的底边被忽略，因为列表栏总是延伸到窗口底边。
    public init(calibratedRect rect: CGRect, in windowFrame: CGRect) {
        let minLength = Self.minimumLength
        let windowWidth = Double(windowFrame.width)
        let windowHeight = Double(windowFrame.height)
        let left = min(max(0, Double(rect.minX - windowFrame.minX)), max(0, windowWidth - minLength))
        let right = min(max(Double(rect.maxX - windowFrame.minX), left + minLength), windowWidth)
        let top = min(max(0, Double(rect.minY - windowFrame.minY)), max(0, windowHeight - minLength))
        self.init(leftInset: left, topInset: top, width: max(0, right - left))
    }

    // 逐字段容错：缺失的字段取默认值（兼容规则见 shared/config.schema.json）
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        leftInset = try container.decodeIfPresent(Double.self, forKey: .leftInset) ?? fallback.leftInset
        topInset = try container.decodeIfPresent(Double.self, forKey: .topInset) ?? fallback.topInset
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? fallback.width
    }
}
