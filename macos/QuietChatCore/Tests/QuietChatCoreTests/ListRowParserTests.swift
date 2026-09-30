import CoreGraphics
import Testing
@testable import QuietChatCore

struct ListRowParserTests {
    private let columnWidth: CGFloat = 240

    /// 合成一行的文字框，版式接近微信的列表：名称和预览左对齐，时间在右侧，未读角标压在头像上。
    /// 没有预览时，名称在行内上下居中。
    private func row(
        at top: CGFloat, name: String, preview: String? = "消息预览", time: String? = "10:32", badge: String? = nil
    ) -> [TextBox] {
        var boxes: [TextBox] = []
        if let preview {
            boxes.append(TextBox(text: name, rect: CGRect(x: 60, y: top + 12, width: 100, height: 17)))
            // 预览的左边缘比名称偏 1 pt，仍在对齐容差内
            boxes.append(TextBox(text: preview, rect: CGRect(x: 61, y: top + 36, width: 140, height: 15)))
        } else {
            boxes.append(TextBox(text: name, rect: CGRect(x: 60, y: top + 23.5, width: 100, height: 17)))
        }
        if let time {
            boxes.append(TextBox(text: time, rect: CGRect(x: 196, y: top + 14, width: 32, height: 12)))
        }
        if let badge {
            boxes.append(TextBox(text: badge, rect: CGRect(x: 40, y: top + 6, width: 10, height: 12)))
        }
        return boxes
    }

    private func band(top: CGFloat, height: CGFloat = 60) -> CGRect {
        CGRect(x: 0, y: top, width: columnWidth, height: height)
    }

    @Test func splitsRowsWithAndWithoutPreview() {
        let boxes = row(at: 0, name: "文件传输助手", badge: "3")
            + row(at: 64, name: "公众号", preview: nil)
            + row(at: 128, name: "服务号", time: "昨天")
            + row(at: 192, name: "滴答清单", time: "星期二", badge: "12")
        // 输入顺序不影响结果
        let rows = ListRowParser.parse(boxes.reversed(), columnWidth: columnWidth)
        #expect(rows == [
            ListRow(name: "文件传输助手", band: band(top: 1.5)),
            ListRow(name: "公众号", band: band(top: 66)),
            ListRow(name: "服务号", band: band(top: 129.5)),
            ListRow(name: "滴答清单", band: band(top: 193.5)),
        ])
    }

    /// 每行只有名称和时间时，两列文字框一样多：取靠左的一列作为正文。
    @Test func prefersLeftColumnWhenNamesAndTimesAreEquallyMany() {
        let boxes = (0..<4).flatMap { row(at: CGFloat($0) * 64, name: "聊天\($0)", preview: nil) }
        let rows = ListRowParser.parse(boxes, columnWidth: columnWidth)
        #expect(rows.map(\.name) == ["聊天0", "聊天1", "聊天2", "聊天3"])
        #expect(rows.map(\.band) == [band(top: 2), band(top: 66), band(top: 130), band(top: 194)])
    }

    @Test func rowHeightFollowsNameSpacing() {
        let boxes = (0..<3).flatMap { row(at: CGFloat($0) * 80, name: "聊天\($0)") }
        let rows = ListRowParser.parse(boxes, columnWidth: columnWidth)
        // 文字块中心在行顶下方 31.5，行高 80：带区从 31.5 - 40 + 2 开始，高 76
        #expect(rows.map(\.band) == [band(top: -6.5, height: 76), band(top: 73.5, height: 76), band(top: 153.5, height: 76)])
    }

    @Test func fewerThanThreeRowsFallBackToDefaultRowHeight() {
        let boxes = row(at: 0, name: "文件传输助手") + row(at: 80, name: "公众号")
        let rows = ListRowParser.parse(boxes, columnWidth: columnWidth)
        #expect(rows.map(\.band) == [band(top: 1.5), band(top: 81.5)])
    }

    /// 个别行没有识别出来时，行高仍然取正常的间距。
    @Test func rowHeightIgnoresMissingRows() {
        let boxes = [0, 1, 3, 4, 5].flatMap { row(at: CGFloat($0) * 64, name: "聊天\($0)") }
        let rows = ListRowParser.parse(boxes, columnWidth: columnWidth)
        #expect(rows.map(\.band) == [0, 1, 3, 4, 5].map { band(top: CGFloat($0) * 64 + 1.5) })
    }

    @Test func trailingTimeIsRemovedFromName() {
        // 名称和右侧的时间被识别成了同一块文字
        let boxes = row(at: 0, name: "文件传输助手 10:32", time: nil)
            + row(at: 64, name: "公众号昨天", time: nil)
            + row(at: 128, name: "服务号  星期二", time: nil)
        #expect(ListRowParser.parse(boxes, columnWidth: columnWidth).map(\.name) == ["文件传输助手", "公众号", "服务号"])

        #expect(ListRowParser.removingTrailingTime("张三 前天") == "张三")
        #expect(ListRowParser.removingTrailingTime("张三 周日") == "张三")
        #expect(ListRowParser.removingTrailingTime("张三 9/18") == "张三")
        #expect(ListRowParser.removingTrailingTime("张三 2026/9/18") == "张三")
        #expect(ListRowParser.removingTrailingTime("张三 26-09-18") == "张三")
        // 不在末尾的时间、不带分隔符的数字都是名称的一部分
        #expect(ListRowParser.removingTrailingTime("3:20 战队") == "3:20 战队")
        #expect(ListRowParser.removingTrailingTime("2024 届校友") == "2024 届校友")
        #expect(ListRowParser.removingTrailingTime("QuietChat 1024") == "QuietChat 1024")
    }

    @Test func emptyInputYieldsNoRows() {
        #expect(ListRowParser.parse([], columnWidth: columnWidth).isEmpty)
    }
}
