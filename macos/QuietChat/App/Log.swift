// 统一日志（os.Logger）。查看方式：
//   log stream --level info --predicate 'subsystem == "io.github.OumCc.QuietChat"'
// 窗口外框、状态等不含隐私的值标记为 public；窗口标题可能包含聊天名称，保持默认的 private。
// 快捷操作只记录阶段、耗时和错误码，不记录配置名称、搜索词或聊天内容。

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "QuietChat"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tracking = Logger(subsystem: subsystem, category: "tracking")
    static let mask = Logger(subsystem: subsystem, category: "mask")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
}
