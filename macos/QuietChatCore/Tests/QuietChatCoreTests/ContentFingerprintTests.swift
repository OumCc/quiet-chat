import Testing
@testable import QuietChatCore

/// 合成的列表画面（BGRA，1 像素 = 1 pt）：每行高 64，有底色、头像色块和一行用小方块画出的"文字"。
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

    /// 画一行：底色铺满整行；头像和文字的颜色不随底色变化，和真实的悬停一样。
    /// - Parameter glyphs: 名称里每个"字"画不画，用来区分不同的名称。
    mutating func drawRow(top: Int, background: UInt8, text: UInt8 = 230, glyphs: [Bool]) {
        fill(x: 0..<width, y: top..<top + Self.rowHeight, gray: background)
        fill(x: 12..<52, y: top + 12..<top + 52, gray: 150)
        for (index, isDrawn) in glyphs.enumerated() where isDrawn {
            fill(x: 60 + index * 14..<71 + index * 14, y: top + 14..<top + 28, gray: text)
        }
    }

    var fingerprint: ContentFingerprint {
        pixels.withUnsafeBytes {
            ContentFingerprint(bgra: $0, width: width, height: height, bytesPerRow: width * 4)
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

    /// 四行的列表；可以指定某一行的底色，也可以把全部内容向下平移。
    private func list(
        background: UInt8 = 47, text: UInt8 = 230, highlightedRow: Int? = nil, highlight: UInt8 = 59,
        names: [[Bool]]? = nil, offset: Int = 0
    ) -> SyntheticList {
        var list = SyntheticList(height: 256, background: background)
        for (index, glyphs) in (names ?? self.names).enumerated() {
            list.drawRow(
                top: index * SyntheticList.rowHeight + offset,
                background: index == highlightedRow ? highlight : background, text: text, glyphs: glyphs)
        }
        return list
    }

    @Test func identicalFramesDoNotDiffer() {
        #expect(!list().fingerprint.differs(from: list().fingerprint))
        // 文字和头像确实被记录了下来，不是因为指纹全空才相同
        #expect(list().fingerprint.strips.contains { $0 != 0 })
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

    /// 行的边界不一定落在水平条的边界上：整体错开 4 像素后，悬停仍然不算变化。
    @Test func rowBackgroundChangeAcrossStripBoundaryIsNotContentChange() {
        let plain = list(offset: 4).fingerprint
        #expect(!plain.differs(from: list(highlightedRow: 1, offset: 4).fingerprint))
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
        #expect(tall.differs(from: short))
    }

    /// 一条里最多允许 3 格不同，留给临界的格；再多就算变化。
    @Test func toleratesAFewCellsPerStrip() {
        let blank = SyntheticList(height: 64).fingerprint
        var threeCells = SyntheticList(height: 64)
        threeCells.fill(x: 100..<115, y: 16..<24, gray: 230)
        var fourCells = SyntheticList(height: 64)
        fourCells.fill(x: 100..<120, y: 16..<24, gray: 230)
        #expect(threeCells.fingerprint.strips[2] == 0b111 << 20)
        #expect(!blank.differs(from: threeCells.fingerprint))
        #expect(blank.differs(from: fourCells.fingerprint))
    }

    /// 亮度按 BGRA 的字节顺序加权：同样是 200，红色明显偏离黑色底色，蓝色不够。
    @Test func luminanceWeightsFollowBGRAOrder() {
        var frame = SyntheticList(height: 8, background: 0)
        frame.fill(x: 0..<10, y: 0..<8, blue: 200, green: 0, red: 0)
        frame.fill(x: 50..<60, y: 0..<8, blue: 0, green: 0, red: 200)
        #expect(frame.fingerprint.strips == [0b11 << 10])
    }

    @Test func lastStripMayBeShorterAndNarrowFramesAreHandled() {
        #expect(SyntheticList(height: 20).fingerprint.strips.count == 3)
        // 宽度小于每条的格数
        var narrow = SyntheticList(width: 40, height: 16)
        #expect(narrow.fingerprint.strips == [0, 0])
        narrow.fill(x: 0..<10, y: 0..<8, gray: 230)
        #expect(narrow.fingerprint.strips[0] != 0)
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
