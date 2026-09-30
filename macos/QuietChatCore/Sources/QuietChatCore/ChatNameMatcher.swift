// 白名单名称匹配：判断识别出的聊天名称是否在白名单中。
// 原则是"宁可多遮"：去掉表情符号和首尾空白后完全一致才算匹配，只是包含不算；
// 只有识别结果以省略号结尾（名称太长，在列表里被截断）时，才按前缀匹配。
// 规则见 docs/architecture.md「精准遮挡」。

import Foundation

/// 聊天名称的规范化与白名单匹配。
public enum ChatNameMatcher {
    /// 截断的名称按前缀匹配时，前缀至少要有的字符数。只会减少露出，用来挡住识别出的零碎文字。
    static let minimumPrefixLength = 2
    /// 算作省略号的字符。列表里画的是"…"，但文字识别会把它读成一到几个句点、居中的省略号或圆点，写法不固定。
    static let ellipsisCharacters: Set<Character> = [".", "…", "⋯", "•", "·"]

    /// 规范化名称：统一为 NFC，去掉表情符号，再去掉首尾空白。
    ///
    /// 表情符号识别不出来，所以比较之前两边都去掉。
    public static func normalize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars where !isEmojiRelated(scalar) {
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 识别出的名称是否与白名单中的某一项匹配。
    public static func isWhitelisted(_ recognized: String, whitelist: [String]) -> Bool {
        let name = normalize(recognized)
        // 规范化后为空的名单项（例如只有表情）不参与匹配，否则识别不出文字的行也会被放行
        let entries = whitelist.map(normalize).filter { !$0.isEmpty }
        if entries.contains(name) { return true }
        guard let prefix = truncatedPrefix(of: name), prefix.count >= minimumPrefixLength else { return false }
        return entries.contains { $0.hasPrefix(prefix) }
    }

    /// 名称以省略号结尾时，返回省略号之前的文字；否则返回 nil。
    ///
    /// 末尾连续的省略号字符不论几个都算；名称本身以句点结尾时也会被当成截断，这是已接受的取舍。
    private static func truncatedPrefix(of name: String) -> String? {
        guard let last = name.last, ellipsisCharacters.contains(last) else { return nil }
        let end = name.lastIndex { !ellipsisCharacters.contains($0) }.map(name.index(after:)) ?? name.startIndex
        return name[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEmojiRelated(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF:
            // 零宽连接符、变体选择符、键帽符号和肤色修饰符：只用来组合或修饰表情
            return true
        default:
            // 数字、#、* 也带有 Emoji 属性，用码位下限把它们留下
            return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0xFF)
        }
    }
}
