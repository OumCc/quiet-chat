// 把识别出的文字框切分成聊天列表的行，得到每一行的名称和带区。
// 坐标约定：列表栏坐标，原点在列表栏左上角、y 向下，单位 pt。
// 只依赖文字之间的位置关系，不依赖颜色，所以深色、浅色模式以及悬停、选中的行都适用。
// 参数按微信 4.x 的列表版式取初值，规则见 docs/architecture.md「精准遮挡」。

import CoreGraphics
import Foundation

/// 一块识别出的文字。
public struct TextBox: Equatable, Sendable {
    public var text: String
    /// 文字的外框（列表栏坐标）。
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// 聊天列表中的一行。
public struct ListRow: Equatable, Sendable {
    /// 聊天名称：名称行的文字，已去掉末尾的时间。
    public var name: String
    /// 这一行占据的带区（列表栏坐标），横向覆盖整个列表栏。
    public var band: CGRect

    public init(name: String, band: CGRect) {
        self.name = name
        self.band = band
    }
}

/// 聊天列表的行切分。
public enum ListRowParser {
    /// 判断文字框是否与正文左边界对齐时允许的偏差。
    static let leftAlignmentTolerance: CGFloat = 4
    /// 相邻两个文字框的上边缘相差超过"框高中位数 × 该系数"时，视为新的一行。
    static let rowBreakFactor: CGFloat = 1.8
    /// 推算行高至少需要的行数；不够时使用 `fallbackRowHeight`。
    static let minimumRowsForSpacing = 3
    static let fallbackRowHeight: CGFloat = 64
    /// 带区上下各内缩的距离，避免露出相邻行的边缘。
    static let bandInset: CGFloat = 2

    /// 把文字框切分成行；没有文字时返回空数组。
    /// - Parameters:
    ///   - boxes: 列表栏里识别出的全部文字框，顺序不限。
    ///   - columnWidth: 列表栏宽度，带区横向覆盖整个列表栏。
    public static func parse(_ boxes: [TextBox], columnWidth: CGFloat) -> [ListRow] {
        guard let leftEdge = bodyLeftEdge(of: boxes) else { return [] }
        // 右侧的时间、头像上的角标不与正文左对齐，不参与切分
        let aligned = boxes
            .filter { abs($0.rect.minX - leftEdge) <= leftAlignmentTolerance }
            .sorted { $0.rect.minY < $1.rect.minY }
        let rowBreak = rowBreakFactor * median(aligned.map(\.rect.height))

        // 每组的第一个框是名称，其余是它下面的消息预览
        var groups: [[TextBox]] = []
        for box in aligned {
            if let previous = groups.last?.last, box.rect.minY - previous.rect.minY <= rowBreak {
                groups[groups.count - 1].append(box)
            } else {
                groups.append([box])
            }
        }

        let rowHeight = rowHeight(of: groups)
        return groups.map { group in
            // 文字块在行内上下居中，以它的中心为行的中心
            let center = (group[0].rect.minY + group[group.count - 1].rect.maxY) / 2
            return ListRow(
                name: removingTrailingTime(group[0].text),
                band: CGRect(
                    x: 0, y: center - rowHeight / 2 + bandInset,
                    width: columnWidth, height: rowHeight - 2 * bandInset))
        }
    }

    /// 去掉名称末尾的时间：名称和它右侧的时间有时会被识别成同一块文字。
    static func removingTrailingTime(_ text: String) -> String {
        text.replacing(
            #/\s*(\d{1,2}:\d{2}|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|\d{1,4}[/\-]\d{1,2}([/\-]\d{1,2})?)$/#,
            with: "")
    }

    /// 正文左边界：被最多文字框共享的左边缘，名称和消息预览都从这里开始。
    private static func bodyLeftEdge(of boxes: [TextBox]) -> CGFloat? {
        let lefts = boxes.map(\.rect.minX)
        func support(_ x: CGFloat) -> Int {
            lefts.count { abs($0 - x) <= leftAlignmentTolerance }
        }
        // 支持数相同时取更靠左的：名称在左，时间在右
        return lefts.max { (support($0), -$0) < (support($1), -$1) }
    }

    /// 行高：相邻两行名称上边缘间距的中位数，个别行没识别出来也不受影响。
    private static func rowHeight(of groups: [[TextBox]]) -> CGFloat {
        guard groups.count >= minimumRowsForSpacing else { return fallbackRowHeight }
        let tops = groups.map { $0[0].rect.minY }
        return median(zip(tops.dropFirst(), tops).map { $0 - $1 })
    }

    /// 中位数；`values` 不能为空。
    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
