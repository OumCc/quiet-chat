import Testing
@testable import QuietChatCore

struct ChatWhitelistTests {
    @Test func dropsBlankLinesAndDuplicates() {
        #expect(ChatWhitelist.normalized(["文件传输助手", "", "  文件传输助手  "]) == ["文件传输助手"])
        #expect(ChatWhitelist.normalized(["", "   ", "\t"]).isEmpty)
    }

    @Test func keepsFirstOccurrenceOrder() {
        #expect(ChatWhitelist.normalized([" 滴答清单", "文件传输助手", "滴答清单 ", "家人群🏠", "文件传输助手"])
            == ["滴答清单", "文件传输助手", "家人群🏠"])
    }

    @Test func keepsInnerWhitespace() {
        #expect(ChatWhitelist.normalized(["  QuietChat 开发讨论群 "]) == ["QuietChat 开发讨论群"])
    }

    @Test func preservesCompleteUnicodeAndPunctuation() {
        let names = ["👩🏽‍💻", "家庭 👨‍👩‍👧‍👦（完整版）", "Acme Inc.", "完整 名称…", "Cafe\u{301}"]
        let normalized = ChatWhitelist.normalized(names.map { " \($0)\n" })
        #expect(normalized == names)
        #expect(normalized.map { Array($0.utf16) } == names.map { Array($0.utf16) })
    }
}
