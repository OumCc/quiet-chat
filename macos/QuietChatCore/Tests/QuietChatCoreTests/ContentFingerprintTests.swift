import Testing
@testable import QuietChatCore

/// 合成的列表画面（BGRA）：每行高 64，有底色、头像色块和一行用小方块画出的"文字"。
/// 方块故意不与指纹的分格对齐，让一部分格只被文字盖住一点，接近真实画面里的抗锯齿边缘。
private struct SyntheticList {
    static let rowHeight = 64

    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int = 240, height: Int, background: UInt8 = 47) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        fill(x: 0..<width, y: 0..<height, blue: background, green: background, red: background)
    }

    mutating func fill(x: Range<Int>, y: Range<Int>, blue: UInt8, green: UInt8, red: UInt8) {
        for row in y.clamped(to: 0..<height) {
            for column in x.clamped(to: 0..<width) {
                let offset = (row * width + column) * 4
                pixels[offset] = blue
                pixels[offset + 1] = green
                pixels[offset + 2] = red
            }
        }
    }

    mutating func fill(x: Range<Int>, y: Range<Int>, gray: UInt8) {
        fill(x: x, y: y, blue: gray, green: gray, red: gray)
    }

    /// 画一行：底色铺满这一行在列表里的部分；头像和文字的颜色不随底色变化，和真实的悬停一样。
    /// - Parameters:
    ///   - listWidth: 列表的宽度；右边剩下的部分不属于列表，悬停时不变色。
    ///   - glyphs: 名称里每个"字"画不画，用来区分不同的名称。
    mutating func drawRow(
        top: Int, background: UInt8, text: UInt8 = 230, avatar: UInt8 = 150, listWidth: Int? = nil, glyphs: [Bool]
    ) {
        fill(x: 0..<(listWidth ?? width), y: top..<top + Self.rowHeight, gray: background)
        fill(x: 12..<52, y: top + 12..<top + 52, gray: avatar)
        for (index, isDrawn) in glyphs.enumerated() where isDrawn {
            fill(x: 60 + index * 14..<71 + index * 14, y: top + 14..<top + 28, gray: text)
        }
    }

    var fingerprint: ContentFingerprint {
        pixels.withUnsafeBytes {
            ContentFingerprint(bgra: $0, width: width, height: height, bytesPerRow: width * 4)
        }
    }

    /// 同一画面在 2 倍分辨率下的指纹：每个像素放大成 2×2。
    var fingerprintAtDoubleResolution: ContentFingerprint {
        var doubled = [UInt8](repeating: 0, count: width * height * 16)
        for y in 0..<height * 2 {
            for x in 0..<width * 2 {
                let source = ((y / 2) * width + x / 2) * 4
                let target = (y * width * 2 + x) * 4
                doubled.replaceSubrange(target..<target + 4, with: pixels[source..<source + 4])
            }
        }
        return doubled.withUnsafeBytes {
            ContentFingerprint(bgra: $0, width: width * 2, height: height * 2, bytesPerRow: width * 8, scale: 2)
        }
    }
}

struct ContentFingerprintTests {
    private let names: [[Bool]] = [
        [true, true, true, false, false],
        [true, false, true, true, true],
        [true, true, false, true, false],
        [false, true, true, true, true],
    ]

    /// 四行的列表。可以指定某一行的底色（悬停）、头像的亮度、把全部内容向下平移，
    /// 或者让画面右边从 `pane.from` 起是另一块区域（取图区域盖到了聊天区）。
    private func list(
        width: Int = 240, background: UInt8 = 47, text: UInt8 = 230, avatar: UInt8 = 150,
        highlightedRow: Int? = nil, highlight: UInt8 = 59, names: [[Bool]]? = nil, offset: Int = 0,
        pane: (from: Int, gray: UInt8)? = nil
    ) -> SyntheticList {
        var list = SyntheticList(width: width, height: 256, background: background)
        for (index, glyphs) in (names ?? self.names).enumerated() {
            list.drawRow(
                top: index * SyntheticList.rowHeight + offset,
                background: index == highlightedRow ? highlight : background,
                text: text, avatar: avatar, listWidth: pane?.from, glyphs: glyphs)
        }
        if let pane {
            list.fill(x: pane.from..<width, y: 0..<256, gray: pane.gray)
        }
        return list
    }

    @Test func identicalFramesDoNotDiffer() {
        #expect(!list().fingerprint.differs(from: list().fingerprint))
        // 文字和头像确实被记录了下来，不是因为指纹全空才相同
        #expect(list().fingerprint.strips.contains { $0.contains { abs($0) > 50 } })
    }

    /// 悬停只让整行的底色小幅变化，不算内容变化；深色和浅色模式都一样。
    @Test func rowBackgroundChangeIsNotContentChange() {
        let dark = list().fingerprint
        for row in 0..<4 {
            #expect(!dark.differs(from: list(highlightedRow: row).fingerprint))
        }
        let light = list(background: 247, text: 25).fingerprint
        for row in 0..<4 {
            #expect(!light.differs(from: list(background: 247, text: 25, highlightedRow: row, highlight: 235).fingerprint))
        }
    }

    /// 悬停后再按下鼠标，底色又亮了一点；相对悬停之前累计变化 16，仍然不算内容变化。
    @Test func hoverThenPressIsNotContentChange() {
        #expect(!list().fingerprint.differs(from: list(highlightedRow: 1, highlight: 63).fingerprint))
    }

    /// 行的边界不一定落在水平条的边界上：整体错开 4 像素后，悬停仍然不算变化。
    @Test func rowBackgroundChangeAcrossStripBoundaryIsNotContentChange() {
        let plain = list(offset: 4).fingerprint
        #expect(!plain.differs(from: list(highlightedRow: 1, offset: 4).fingerprint))
    }

    /// 头像的亮度和底色相差不多时，悬停不能被当成内容变化。
    /// 每格只记"是否偏离底色超过某个值"的做法在这里会整片翻转。
    @Test func hoverOverRowWithAvatarCloseToBackgroundIsNotContentChange() {
        let brighterAvatar = list(avatar: 75).fingerprint
        #expect(!brighterAvatar.differs(from: list(avatar: 75, highlightedRow: 1, highlight: 58).fingerprint))

        let darkerAvatar = list(background: 59, avatar: 35).fingerprint
        #expect(!darkerAvatar.differs(from: list(background: 59, avatar: 35, highlightedRow: 2, highlight: 69).fingerprint))
    }

    /// 取图区域右边盖到了别的区块（例如窗口变窄后的聊天区），那一块不随悬停变色：仍然不算内容变化。
    @Test func hoverIsNotContentChangeWhenRegionCoversAnotherPane() {
        let pane = (from: 200, gray: UInt8(25))
        let plain = list(background: 48, pane: pane).fingerprint
        for highlight: UInt8 in [54, 59] {
            let hovered = list(background: 48, highlightedRow: 1, highlight: highlight, pane: pane).fingerprint
            #expect(!plain.differs(from: hovered))
        }
    }

    @Test func textChangeIsContentChange() {
        var changed = names
        changed[1] = [true, true, false, false, true]
        #expect(list().fingerprint.differs(from: list(names: changed).fingerprint))
    }

    @Test func reorderedRowsAreContentChange() {
        var reordered = names
        reordered.swapAt(0, 2)
        #expect(list().fingerprint.differs(from: list(names: reordered).fingerprint))
    }

    @Test func scrollingIsContentChange() {
        #expect(list().fingerprint.differs(from: list(offset: 20).fingerprint))
        #expect(list().fingerprint.differs(from: list(offset: -20).fingerprint))
    }

    @Test func differentHeightIsContentChange() {
        let tall = SyntheticList(height: 256).fingerprint
        let short = SyntheticList(height: 192).fingerprint
        #expect(tall.strips.count == 32)
        #expect(short.strips.count == 24)
        #expect(tall.differingCellCounts(from: short) == nil)
        #expect(tall.differs(from: short))
    }

    /// 一条里最多允许 3 格变化，留给输入光标闪动之类的小变化；再多就算内容变化。
    @Test func toleratesAFewCellsPerStrip() {
        let blank = SyntheticList(height: 64).fingerprint
        var threeCells = SyntheticList(height: 64)
        threeCells.fill(x: 100..<115, y: 16..<24, gray: 230)
        var fourCells = SyntheticList(height: 64)
        fourCells.fill(x: 100..<120, y: 16..<24, gray: 230)
        #expect(blank.differingCellCounts(from: threeCells.fingerprint) == [0, 0, 3, 0, 0, 0, 0, 0])
        #expect(!blank.differs(from: threeCells.fingerprint))
        #expect(blank.differingCellCounts(from: fourCells.fingerprint) == [0, 0, 4, 0, 0, 0, 0, 0])
        #expect(blank.differs(from: fourCells.fingerprint))
    }

    /// 偏差变化不超过 20 的格不算变化：整块亮度只差 15 的新内容不会被判为变化，差 30 的会。
    @Test func smallDeviationChangesAreIgnored() {
        let blank = SyntheticList(height: 64).fingerprint
        var faint = SyntheticList(height: 64)
        faint.fill(x: 100..<140, y: 16..<24, gray: 62)
        var visible = SyntheticList(height: 64)
        visible.fill(x: 100..<140, y: 16..<24, gray: 77)
        #expect(!blank.differs(from: faint.fingerprint))
        #expect(blank.differs(from: visible.fingerprint))
    }

    /// 亮度按 BGRA 的字节顺序加权：同样是 200，蓝色块的亮度约 22.8，红色块约 59.8。
    @Test func luminanceWeightsFollowBGRAOrder() throws {
        var frame = SyntheticList(height: 8, background: 0)
        frame.fill(x: 0..<10, y: 0..<8, blue: 200, green: 0, red: 0)
        frame.fill(x: 50..<60, y: 0..<8, blue: 0, green: 0, red: 200)
        let strip = try #require(frame.fingerprint.strips.first)
        #expect(strip.count == 48)
        for (cell, deviation) in strip.enumerated() {
            let expected: Float = cell < 2 ? 22.8 : (10...11).contains(cell) ? 59.8 : 0
            #expect(abs(deviation - expected) < 0.01, "第 \(cell) 格")
        }
    }

    /// 同一画面在 1 倍和 2 倍分辨率下的指纹一致：条的高度按 pt 计算。
    @Test func sameFrameAtDoubleResolutionHasTheSameFingerprint() {
        let frame = list()
        #expect(frame.fingerprintAtDoubleResolution == frame.fingerprint)
        // 宽度不能被格数整除时，两种分辨率下格的边界差一个像素，指纹略有出入，但不会判为变化
        let odd = list(width: 242)
        #expect(!odd.fingerprintAtDoubleResolution.differs(from: odd.fingerprint))
    }

    @Test func lastStripMayBeShorterAndNarrowFramesAreHandled() {
        #expect(SyntheticList(height: 20).fingerprint.strips.count == 3)
        // 宽度小于每条的格数
        var narrow = SyntheticList(width: 40, height: 16)
        #expect(narrow.fingerprint.strips.count == 2)
        #expect(narrow.fingerprint.strips.allSatisfy { $0.allSatisfy { $0 == 0 } })
        narrow.fill(x: 0..<10, y: 0..<8, gray: 230)
        #expect(narrow.fingerprint.strips[0].contains { $0 != 0 })
    }

    @Test func mismatchedBufferYieldsEmptyFingerprint() {
        let pixels = [UInt8](repeating: 0, count: 16)
        let fingerprint = pixels.withUnsafeBytes {
            ContentFingerprint(bgra: $0, width: 240, height: 64, bytesPerRow: 960)
        }
        #expect(fingerprint.strips.isEmpty)
        // 读不出画面时按"变化"处理，已露出的行会被盖住
        #expect(fingerprint.differs(from: SyntheticList(height: 64).fingerprint))
    }
}

struct ContentChangeTrackerTests {
    /// 只有一条的指纹：在第 `cells` 格画上内容，亮度为 `gray`。
    private func fingerprint(cells: Range<Int> = 0..<0, gray: UInt8 = 230) -> ContentFingerprint {
        var frame = SyntheticList(height: 8)
        frame.fill(x: cells.lowerBound * 5..<cells.upperBound * 5, y: 0..<8, gray: gray)
        return frame.fingerprint
    }

    @Test func firstFrameIsAChangeAndTheNextIdenticalOneSettles() {
        var tracker = ContentChangeTracker()
        let first = tracker.observe(fingerprint(cells: 10..<20))
        let second = tracker.observe(fingerprint(cells: 10..<20))
        let third = tracker.observe(fingerprint(cells: 10..<20))
        #expect(first == .changed)
        #expect(second == .settled)
        // 稳定只报告一次
        #expect(third == .unchanged)
    }

    @Test func differentFrameIsAChangeAndMustSettleAgain() {
        var tracker = ContentChangeTracker()
        _ = tracker.observe(fingerprint(cells: 10..<20))
        _ = tracker.observe(fingerprint(cells: 10..<20))
        let changed = tracker.observe(fingerprint(cells: 30..<40))
        let stillChanging = tracker.observe(fingerprint(cells: 20..<30))
        let settled = tracker.observe(fingerprint(cells: 20..<30))
        #expect(changed == .changed)
        #expect(stillChanging == .changed)
        #expect(settled == .settled)
    }

    /// 每一张都只比上一张多变 2 格，单看相邻两张都不算变化；和基准帧比，累计超过 3 格时就判为变化。
    @Test func slowDriftIsCaughtAgainstTheReferenceFrame() {
        var tracker = ContentChangeTracker()
        _ = tracker.observe(fingerprint())
        _ = tracker.observe(fingerprint())
        let twoCells = tracker.observe(fingerprint(cells: 10..<12))
        let fourCells = tracker.observe(fingerprint(cells: 10..<14))
        #expect(twoCells == .unchanged)
        #expect(!fingerprint(cells: 10..<12).differs(from: fingerprint(cells: 10..<14)))
        #expect(fourCells == .changed)
    }

    /// 悬停这样的底色变化不算变化，不会打断已经稳定的状态。
    @Test func backgroundOnlyChangeKeepsTheFrameSettled() {
        var tracker = ContentChangeTracker()
        var hovered = SyntheticList(height: 8, background: 58)
        hovered.fill(x: 50..<100, y: 0..<8, gray: 230)
        _ = tracker.observe(fingerprint(cells: 10..<20))
        _ = tracker.observe(fingerprint(cells: 10..<20))
        let verdict = tracker.observe(hovered.fingerprint)
        #expect(verdict == .unchanged)
    }

    @Test func invalidateMakesTheNextFrameAChangeEvenIfIdentical() {
        var tracker = ContentChangeTracker()
        _ = tracker.observe(fingerprint(cells: 10..<20))
        _ = tracker.observe(fingerprint(cells: 10..<20))
        tracker.invalidate()
        let afterInvalidate = tracker.observe(fingerprint(cells: 10..<20))
        let settled = tracker.observe(fingerprint(cells: 10..<20))
        #expect(afterInvalidate == .changed)
        #expect(settled == .settled)
    }

    /// 画面高度变了（窗口缩放）：条数不同，按变化处理。
    @Test func frameOfDifferentHeightIsAChange() {
        var tracker = ContentChangeTracker()
        _ = tracker.observe(SyntheticList(height: 64).fingerprint)
        _ = tracker.observe(SyntheticList(height: 64).fingerprint)
        let resized = tracker.observe(SyntheticList(height: 80).fingerprint)
        #expect(resized == .changed)
    }
}
