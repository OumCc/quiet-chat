// 白名单的整理规则：保存用户填写的聊天名称之前统一处理。
// 这里只做文字层面的清理；名称与识别结果如何比较见 ChatNameMatcher。

import Foundation

/// 精准遮挡要露出的聊天名单。
public enum ChatWhitelist {
    /// 整理用户填写的名称：去掉首尾空白，丢弃空行；重复的名称只保留第一次出现的，其余顺序不变。
    public static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !seen.insert(trimmed).inserted ? nil : trimmed
        }
    }
}
