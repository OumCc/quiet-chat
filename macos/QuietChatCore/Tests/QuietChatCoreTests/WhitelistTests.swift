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
}

struct ChatNameMatcherTests {
    @Test func exactNameMatches() {
        #expect(ChatNameMatcher.isWhitelisted("文件传输助手", whitelist: ["滴答清单", "文件传输助手"]))
        #expect(ChatNameMatcher.isWhitelisted("  文件传输助手 ", whitelist: [" 文件传输助手"]))
    }

    @Test func containingWhitelistedNameIsNotEnough() {
        #expect(!ChatNameMatcher.isWhitelisted("张三丰", whitelist: ["张三"]))
        #expect(!ChatNameMatcher.isWhitelisted("张三", whitelist: ["张三丰"]))
        #expect(!ChatNameMatcher.isWhitelisted("小张三", whitelist: ["张三"]))
    }

    @Test func emojiIsIgnoredOnBothSides() {
        #expect(ChatNameMatcher.isWhitelisted("家人群", whitelist: ["家人群🏠"]))
        #expect(ChatNameMatcher.isWhitelisted("家人群 🏠", whitelist: ["家人群"]))
        // 组合表情：家庭（零宽连接符）、肤色修饰符、键帽、带变体选择符的符号
        #expect(ChatNameMatcher.normalize("👨‍👩‍👧家人👍🏽群☺️") == "家人群")
        #expect(ChatNameMatcher.normalize("1️⃣号群") == "1号群")
    }

    @Test func normalizationKeepsDigitsAndAsciiSymbols() {
        #expect(ChatNameMatcher.normalize(" #1 群* (2024) ") == "#1 群* (2024)")
    }

    @Test func normalizationComposesCharacters() {
        // e + 组合重音符 → é
        #expect(Array(ChatNameMatcher.normalize("Cafe\u{301}").unicodeScalars) == Array("Caf\u{E9}".unicodeScalars))
    }

    @Test func truncatedNameMatchesByPrefix() {
        let whitelist = ["QuietChat 开发讨论群"]
        #expect(ChatNameMatcher.isWhitelisted("QuietChat 开发…", whitelist: whitelist))
        #expect(ChatNameMatcher.isWhitelisted("QuietChat 开发...", whitelist: whitelist))
        #expect(ChatNameMatcher.isWhitelisted("QuietChat 开发 …", whitelist: whitelist))
        // 没有省略号就不是截断，只是名单名称的一部分
        #expect(!ChatNameMatcher.isWhitelisted("QuietChat 开发", whitelist: whitelist))
        #expect(!ChatNameMatcher.isWhitelisted("QuietChat 测试…", whitelist: whitelist))
    }

    /// 文字识别把列表里的"…"读成各种写法，都按省略号处理。
    @Test func ellipsisIsRecognizedInEveryObservedSpelling() {
        let whitelist = ["周末羽毛球爱好者交流群"]
        for ellipsis in ["…", "...", "..", ".", "⋯", "⋯.", "⋯..", "….", "•", "••", "·", ".⋯.", "...."] {
            #expect(
                ChatNameMatcher.isWhitelisted("周末羽毛球爱好者" + ellipsis, whitelist: whitelist),
                "末尾为 \(ellipsis) 时应按截断处理")
        }
        // 省略号之前的文字必须是名单名称的开头
        #expect(!ChatNameMatcher.isWhitelisted("羽毛球爱好者..", whitelist: whitelist))
        // 其他标点不是省略号
        #expect(!ChatNameMatcher.isWhitelisted("周末羽毛球爱好者。", whitelist: whitelist))
        #expect(!ChatNameMatcher.isWhitelisted("周末羽毛球爱好者-", whitelist: whitelist))
    }

    /// 名单名称本身带句点时，完全一致的匹配不受截断规则影响。
    @Test func whitelistedNameEndingWithPeriodStillMatchesExactly() {
        #expect(ChatNameMatcher.isWhitelisted("Acme Inc.", whitelist: ["Acme Inc."]))
        #expect(!ChatNameMatcher.isWhitelisted("Acme Inc", whitelist: ["Acme Inc."]))
    }

    @Test func truncatedPrefixShorterThanTwoCharactersNeverMatches() {
        #expect(!ChatNameMatcher.isWhitelisted("张…", whitelist: ["张三"]))
        #expect(!ChatNameMatcher.isWhitelisted("…", whitelist: ["张三"]))
        #expect(!ChatNameMatcher.isWhitelisted("...", whitelist: ["张三"]))
        #expect(ChatNameMatcher.isWhitelisted("张三…", whitelist: ["张三丰"]))
    }

    @Test func everyRowWithTheSameNameMatches() {
        let recognized = ["张三", "李四", "张三"]
        #expect(recognized.map { ChatNameMatcher.isWhitelisted($0, whitelist: ["张三"]) } == [true, false, true])
    }

    @Test func emptyNamesNeverMatch() {
        #expect(!ChatNameMatcher.isWhitelisted("", whitelist: ["张三"]))
        #expect(!ChatNameMatcher.isWhitelisted("张三", whitelist: []))
        // 只有表情的名单项规范化后为空，不能让识别不出文字的行匹配上
        #expect(!ChatNameMatcher.isWhitelisted("", whitelist: ["🏠", "  "]))
        #expect(!ChatNameMatcher.isWhitelisted("🏠", whitelist: ["🏠"]))
    }
}
