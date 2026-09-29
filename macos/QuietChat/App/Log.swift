// 统一日志（os.Logger）。查看方式：
//   log stream --level info --predicate 'subsystem == "io.github.OumCc.QuietChat"'
// 窗口外框、状态等不含隐私的值标记为 public；窗口标题可能包含聊天名称，保持默认的 private。

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "QuietChat"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tracking = Logger(subsystem: subsystem, category: "tracking")
    static let mask = Logger(subsystem: subsystem, category: "mask")
}
