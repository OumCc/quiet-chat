import CoreGraphics
import CoreText
import Foundation
import QuietChatCore
import QuietChatDetection
import Testing

/// 用 CoreText 画出来的聊天列表，版式按微信 4.x 取：每行高 64 pt，左侧头像，名称在上、预览在下，时间靠右。
/// 真实截图里有聊天名称和消息预览，不放进仓库，识别流程用这种合成图片测试。
private struct SyntheticChatList {
    struct Row {
        var name: String
        var preview: String
        var time: String
    }

    enum Appearance: CaseIterable {
        case dark, light, darkWithHoveredRow

        var isDark: Bool { self != .light }
        var hoveredRow: Int? { self == .darkWithHoveredRow ? 2 : nil }
    }

    static let width: CGFloat = 242
    static let rowHeight: CGFloat = 64
    static let scale: CGFloat = 2

    static let rows = [
        Row(name: "文件传输助手", preview: "[图片]", time: "10:32"),
        Row(name: "公众号", preview: "某某日报：今日要闻速览", time: "09:15"),
        Row(name: "滴答清单", preview: "你有 3 个任务即将到期", time: "昨天"),
        Row(name: "张三丰", preview: "好的，明天见", time: "星期二"),
        // 名称太长，画出来会被截断成"周末羽毛球爱好者…"
        Row(name: "周末羽毛球爱好者交流群", preview: "王五：[动画表情]", time: "9/18"),
        Row(name: "服务号", preview: "您的快递已签收", time: "9/17"),
    ]

    var appearance: Appearance

    /// 第 index 行在图片中的位置（列表栏坐标）。
    static func frame(ofRow index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
    }

    func makeImage() throws -> CGImage {
        let height = Self.rowHeight * CGFloat(Self.rows.count)
        let context = try #require(CGContext(
            data: nil, width: Int(Self.width * Self.scale), height: Int(height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: Self.scale, y: Self.scale)

        let dark = appearance.isDark
        let primary = Self.gray(dark ? 0xE9 : 0x19)
        let secondary = Self.gray(dark ? 0x8C : 0x9E)
        for (index, row) in Self.rows.enumerated() {
            let top = CGFloat(index) * Self.rowHeight
            // CoreGraphics 的原点在左下角：距顶部 top、高 h 的矩形，y 为 height - top - h
            func fromTop(_ offset: CGFloat, height rectHeight: CGFloat) -> CGFloat { height - top - offset - rectHeight }

            // 悬停只让整行底色变亮一点，头像和文字不变
            let hovered = index == appearance.hoveredRow
            context.setFillColor(Self.gray(dark ? (hovered ? 0x39 : 0x2F) : (hovered ? 0xEA : 0xF7)))
            context.fill(CGRect(x: 0, y: fromTop(0, height: Self.rowHeight), width: Self.width, height: Self.rowHeight))

            context.setFillColor(CGColor(
                srgbRed: CGFloat((index * 53) % 160 + 60) / 255, green: CGFloat((index * 97) % 160 + 60) / 255,
                blue: CGFloat((index * 31) % 160 + 60) / 255, alpha: 1))
            context.addPath(CGPath(
                roundedRect: CGRect(x: 12, y: fromTop(12, height: 40), width: 40, height: 40),
                cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()

            let timeWidth = Self.draw(
                row.time, size: 11, color: secondary, in: context, rightEdge: Self.width - 10, top: height - top - 15)
            Self.draw(
                row.name, size: 14, color: primary, in: context, leftEdge: 58, top: height - top - 12,
                maxWidth: Self.width - 10 - timeWidth - 8 - 58)
            Self.draw(
                row.preview, size: 12, color: secondary, in: context, leftEdge: 58, top: height - top - 35,
                maxWidth: Self.width - 10 - 58)
        }
        return try #require(context.makeImage())
    }

    private static func gray(_ value: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(value) / 255, green: CGFloat(value) / 255, blue: CGFloat(value) / 255, alpha: 1)
    }

    /// 画一行文字，放不下时像微信一样在末尾截断成"…"；返回画出的宽度。
    /// - Parameter top: 文字上边缘的 y 坐标（原点在左下角）。
    @discardableResult
    private static func draw(
        _ text: String, size: CGFloat, color: CGColor, in context: CGContext,
        leftEdge: CGFloat? = nil, rightEdge: CGFloat = 0, top: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, size, "zh-Hans" as CFString)
            ?? CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        func makeLine(_ string: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
        }
        var line = makeLine(text)
        var ascent: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        if width > maxWidth, let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, makeLine("…")) {
            line = truncated
            width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        }
        context.textPosition = CGPoint(x: leftEdge ?? rightEdge - width, y: top - ascent)
        CTLineDraw(line, context)
        return width
    }
}

/// 完整的识别流程：图片 → 文字框 → 行 → 白名单匹配。
struct ChatListRecognitionTests {
    /// "张三"只是"张三丰"的一部分，不应该让那一行露出。
    private static let whitelist = ["文件传输助手", "滴答清单", "张三", "周末羽毛球爱好者交流群"]
    private static let whitelistedRows = [0, 2]
    /// 名称被截断、靠前缀匹配的行。
    private static let truncatedRow = 4

    private func revealedBands(_ appearance: SyntheticChatList.Appearance) throws -> [CGRect] {
        let image = try SyntheticChatList(appearance: appearance).makeImage()
        let boxes = try TextRecognizer.recognize(image, scale: SyntheticChatList.scale, customWords: Self.whitelist)
        return ListRowParser.parse(boxes, columnWidth: SyntheticChatList.width)
            .filter { ChatNameMatcher.isWhitelisted($0.name, whitelist: Self.whitelist) }
            .map(\.band)
    }

    /// 交并比：两个矩形重合得越好越接近 1。
    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / (lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea)
    }

    @Test(arguments: SyntheticChatList.Appearance.allCases)
    private func revealsWhitelistedRows(_ appearance: SyntheticChatList.Appearance) throws {
        let bands = try revealedBands(appearance)
        for row in Self.whitelistedRows {
            let frame = SyntheticChatList.frame(ofRow: row)
            #expect(bands.contains { overlap($0, frame) > 0.8 }, "第 \(row) 行应该露出")
        }
    }

    @Test(arguments: SyntheticChatList.Appearance.allCases)
    private func revealsTruncatedName(_ appearance: SyntheticChatList.Appearance) throws {
        let bands = try revealedBands(appearance)
        let frame = SyntheticChatList.frame(ofRow: Self.truncatedRow)
        #expect(bands.contains { overlap($0, frame) > 0.8 })
    }

    @Test(arguments: SyntheticChatList.Appearance.allCases)
    private func keepsOtherRowsMasked(_ appearance: SyntheticChatList.Appearance) throws {
        let allowed = (Self.whitelistedRows + [Self.truncatedRow]).map(SyntheticChatList.frame(ofRow:))
        for band in try revealedBands(appearance) {
            #expect(allowed.contains { overlap(band, $0) > 0.8 }, "露出的带区 \(band) 不对应任何白名单行")
        }
    }
}
