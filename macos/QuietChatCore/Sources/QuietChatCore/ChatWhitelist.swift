// 白名单的整理规则：保存用户填写的聊天名称之前统一处理。
// 只清理首尾空白和重复项，保留用于键盘搜索的完整内容与顺序。

import Foundation

/** 静态快捷入口使用的完整聊天名称名单。 */
public enum ChatWhitelist {
    /** 去掉首尾空白和空项，重复名称保留首次出现；不删除表情、标点或内部空白。 */
    public static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !seen.insert(trimmed).inserted ? nil : trimmed
        }
    }
}
