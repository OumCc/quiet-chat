// 列表画面的"去底色指纹"：用来判断聊天列表的内容（文字、图标、行的排列）有没有变化。
// 做法：把画面切成水平条，每条再横向分格，每格只记录"亮度是否明显偏离这一条的底色"。
// 鼠标悬停只让整行的底色一起小幅变化：每格都是贯穿整条高度的竖切片，行的边界即使落在一条中间，
// 这一条里纯底色的格变化量也相同，底色（各格亮度的中位数）跟着变，指纹不变；文字或图标一变，对应的格就会翻转。
// 选中不在此列：选中行的底色变化很大（微信深色模式下是绿色），文字、头像与底色的对比随之改变，会被判为内容变化。
// 参数为初值，对应 1 倍分辨率（1 像素 = 1 pt）的画面。规则见 docs/architecture.md「精准遮挡」。

import Foundation

/// 一帧列表画面的内容指纹。
public struct ContentFingerprint: Equatable, Sendable {
    /// 每条的高度（像素）。
    static let stripHeight = 8
    /// 每条横向分成的格数。
    static let cellsPerStrip = 48
    /// 一格的平均亮度与这一条的底色相差超过该值（0～255）时，记为有内容。
    static let contentThreshold = 24.0
    /// 一条里允许不同的格数，留给抗锯齿造成的临界格；超过就算内容变化。
    static let maxDifferingCells = 3

    /// 每条一个位图：第 i 位为 1 表示从左数第 i 格有内容。
    public let strips: [UInt64]

    /// 计算一帧画面的指纹；尺寸与缓冲区对不上时得到空指纹。
    /// - Parameters:
    ///   - pixels: BGRA 像素，每像素 4 字节，第 0 行是画面顶部。
    ///   - bytesPerRow: 每行占用的字节数，可以大于 `width * 4`。
    public init(bgra pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              pixels.count >= (height - 1) * bytesPerRow + width * 4 else {
            strips = []
            return
        }
        let cellCount = Self.cellsPerStrip
        // 画面比格数还窄时，相邻的格共用像素列，保证每格至少一列
        let cellColumns = (0..<cellCount).map { cell -> Range<Int> in
            let start = cell * width / cellCount
            return start..<max(start + 1, (cell + 1) * width / cellCount)
        }
        strips = stride(from: 0, to: height, by: Self.stripHeight).map { top in
            let rows = top..<min(top + Self.stripHeight, height)
            let luminances = cellColumns.map { columns -> Double in
                var sum = 0
                for y in rows {
                    for x in columns {
                        let offset = y * bytesPerRow + x * 4
                        // 字节顺序为蓝、绿、红、透明度
                        sum += 114 * Int(pixels[offset]) + 587 * Int(pixels[offset + 1]) + 299 * Int(pixels[offset + 2])
                    }
                }
                return Double(sum) / Double(1000 * rows.count * columns.count)
            }
            let sorted = luminances.sorted()
            let background = (sorted[cellCount / 2 - 1] + sorted[cellCount / 2]) / 2
            var bits: UInt64 = 0
            for (cell, luminance) in luminances.enumerated() where abs(luminance - background) > Self.contentThreshold {
                bits |= 1 << UInt64(cell)
            }
            return bits
        }
    }

    /// 与另一帧相比，内容是否发生了变化；画面高度不同（条数不同）也算变化。
    public func differs(from other: ContentFingerprint) -> Bool {
        guard strips.count == other.strips.count else { return true }
        return zip(strips, other.strips).contains { ($0 ^ $1).nonzeroBitCount > Self.maxDifferingCells }
    }
}
