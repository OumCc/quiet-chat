// 统一日志（os.Logger）。查看方式：
//   log stream --level info --predicate 'subsystem == "io.github.OumCc.QuietChat"'
// 窗口外框、状态等不含隐私的值标记为 public；窗口标题可能包含聊天名称，保持默认的 private。
// 精准遮挡识别出的文字一律不写入日志，只记录次数、耗时和错误码。

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "QuietChat"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tracking = Logger(subsystem: subsystem, category: "tracking")
    static let mask = Logger(subsystem: subsystem, category: "mask")
    static let capture = Logger(subsystem: subsystem, category: "capture")
}
