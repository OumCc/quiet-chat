// 从微信经辅助功能接口暴露的窗口中挑出聊天主窗口。
// 微信 4.x 基于 Qt，同一进程会有多个窗口（独立聊天窗口、图片查看器、提示框等）。
// 这里只做纯判断，便于单测；Windows 端按同一规则实现。

import CoreGraphics

/// 参与主窗口判断的窗口属性。
public struct WindowCandidate: Equatable, Sendable {
    public var title: String?
    /// 辅助功能子角色，例如 `AXStandardWindow`、`AXDialog`。
    public var subrole: String?
    public var size: CGSize

    public init(title: String?, subrole: String?, size: CGSize) {
        self.title = title
        self.subrole = subrole
        self.size = size
    }
}

/// 微信主窗口的挑选规则。
public enum MainWindowSelector {
    /// 主窗口可能使用的标题（随界面语言不同）。
    public static let mainWindowTitles: Set<String> = ["微信", "WeChat", "Weixin"]
    /// 主窗口的最小尺寸；更小的是提示框、浮层之类。
    public static let minimumSize = CGSize(width: 400, height: 300)

    /// 返回主窗口在 `candidates` 中的下标，没有合适的窗口时返回 nil。
    ///
    /// 只考虑足够大的标准窗口：标题是应用名的优先，否则取面积最大的。
    public static func selectMainWindow(from candidates: [WindowCandidate]) -> Int? {
        let eligible = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.subrole == "AXStandardWindow"
                && candidate.size.width >= minimumSize.width
                && candidate.size.height >= minimumSize.height
        }
        if let titled = eligible.first(where: { candidates[$0].title.map(mainWindowTitles.contains) ?? false }) {
            return titled
        }
        return eligible.max { area(of: candidates[$0]) < area(of: candidates[$1]) }
    }

    private static func area(of candidate: WindowCandidate) -> CGFloat {
        candidate.size.width * candidate.size.height
    }
}
