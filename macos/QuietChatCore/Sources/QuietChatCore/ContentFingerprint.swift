// 列表画面的"去底色指纹"：用来判断聊天列表的内容（文字、图标、行的排列）有没有变化。
// 做法：把画面切成水平条，每条再横向分格，每格记录"平均亮度减去这一条的底色"，即偏差；
// 两帧之间某格的偏差变化超过阈值，才算这一格变了。
// 鼠标悬停只让整行的底色一起小幅变化：各格亮度的变化量都不超过底色的变化量，底色（各格亮度的中位数）也一样，
// 所以每格偏差的变化不会超过底色的变化量，达不到阈值；文字或图标一变，对应格的偏差会变化几十。
// 选中不在此列：选中行的底色变化很大（微信深色模式下是绿色），会被判为内容变化。
// 参数为初值，规则见 docs/architecture.md「精准遮挡」。

import Foundation

/// 一帧列表画面的内容指纹。
public struct ContentFingerprint: Equatable, Sendable {
    /// 每条的高度（pt）。
    static let stripHeight = 8
    /// 每条横向分成的格数。
    static let cellsPerStrip = 48
    /// 一格的偏差变化超过该值（亮度 0～255）才算这一格变了。
    /// 要大于悬停造成的底色变化（实测最大 11），小于文字、头像变动带来的变化。
    static let cellChangeThreshold: Float = 20
    /// 一条里允许变化的格数，留给输入光标闪动之类的小变化；超过就算内容变化。
    static let maxDifferingCells = 3

    /// 每条 `cellsPerStrip` 个值：各格的平均亮度减去这一条的底色（各格亮度的中位数）。
    let strips: [[Float]]

    /// 计算一帧画面的指纹；尺寸与缓冲区对不上时得到空指纹。
    /// - Parameters:
    ///   - pixels: BGRA 像素，每像素 4 字节，第 0 行是画面顶部。
    ///   - bytesPerRow: 每行占用的字节数，可以大于 `width * 4`。
    ///   - scale: 每 pt 对应的像素数（Retina 屏为 2）。条的高度按 pt 计算，同一画面在不同分辨率下得到的指纹基本一致；
    ///     但缩放方式不同的两张图不能互相比较，调用方应始终用同一种分辨率。
    public init(bgra pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, scale: Int = 1) {
        guard width > 0, height > 0, scale > 0, bytesPerRow >= width * 4,
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
        let stripPixelHeight = Self.stripHeight * scale
        strips = stride(from: 0, to: height, by: stripPixelHeight).map { top in
            let rows = top..<min(top + stripPixelHeight, height)
            let luminances = cellColumns.map { columns -> Float in
                var sum = 0
                for y in rows {
                    for x in columns {
                        let offset = y * bytesPerRow + x * 4
                        // 字节顺序为蓝、绿、红、透明度
                        sum += 114 * Int(pixels[offset]) + 587 * Int(pixels[offset + 1]) + 299 * Int(pixels[offset + 2])
                    }
                }
                // 用 Double 做除法：像素数翻倍时结果完全相同，不受 Float 精度影响
                return Float(Double(sum) / Double(1000 * rows.count * columns.count))
            }
            let sorted = luminances.sorted()
            let background = (sorted[cellCount / 2 - 1] + sorted[cellCount / 2]) / 2
            return luminances.map { $0 - background }
        }
    }

    /// 与另一帧相比，每条里偏差变化超过阈值的格数；条数不同（画面高度变了）时返回 nil。
    func differingCellCounts(from other: ContentFingerprint) -> [Int]? {
        guard strips.count == other.strips.count else { return nil }
        return zip(strips, other.strips).map { lhs, rhs in
            zip(lhs, rhs).reduce(0) { abs($1.0 - $1.1) > Self.cellChangeThreshold ? $0 + 1 : $0 }
        }
    }

    /// 与另一帧相比，内容是否发生了变化；画面高度不同（条数不同）也算变化。
    public func differs(from other: ContentFingerprint) -> Bool {
        guard let counts = differingCellCounts(from: other) else { return true }
        return counts.contains { $0 > Self.maxDifferingCells }
    }
}
