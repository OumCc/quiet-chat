// 遮罩决策：根据主窗口快照和列表栏布局，决定遮罩显示在哪里、要不要收起。
// 原则是"宁可多遮，不漏出"：只有明确压在微信之上的其他窗口，才会在遮罩上开洞让出位置。
// 显示规则对应 docs/architecture.md「显示规则」一节。

import CoreGraphics

/// 一次遮罩的几何结果（Quartz 全局坐标）。
public struct MaskPlan: Equatable, Sendable {
    /// 遮罩覆盖的区域，即列表栏矩形。
    public var maskRect: CGRect
    /// 遮罩上不绘制的区域：其他窗口压在微信之上的部分，已裁剪到 `maskRect` 内。
    public var holes: [CGRect]

    public init(maskRect: CGRect, holes: [CGRect]) {
        self.maskRect = maskRect
        self.holes = holes
    }

    /// 以遮罩左上角为原点、y 向下的局部坐标表示的洞，供坐标系翻转的视图直接绘制。
    public var holesInMaskCoordinates: [CGRect] {
        holes.map { $0.offsetBy(dx: -maskRect.minX, dy: -maskRect.minY) }
    }
}

/// 遮罩应该如何变化。
public enum MaskDecision: Equatable, Sendable {
    /// 显示在指定位置。
    case show(MaskPlan)
    /// 收起。
    case hide
    /// 保持现状：主窗口在另一个桌面上，遮罩和它一起留在那里，切回来时随桌面一起出现。
    case keep
}

/// 遮罩的几何计算与显示规则。
public enum MaskPlanner {
    /// 计算遮罩的位置和洞；列表栏与窗口没有交集时返回 nil。遮罩和洞都落在整点上。
    public static func plan(windowFrame: CGRect, layout: ListColumnLayout, occluders: [CGRect]) -> MaskPlan? {
        guard let maskRect = layout.rect(in: windowFrame) else { return nil }
        let holes = occluders.compactMap { occluder -> CGRect? in
            let overlap = occluder.intersection(maskRect)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            // 洞向外取整后再裁回遮罩内：上层窗口边缘不会压着一条没清干净的遮罩
            return overlap.integral.intersection(maskRect)
        }
        return MaskPlan(maskRect: maskRect, holes: holes)
    }

    /// 决定遮罩下一步的状态。
    /// - Parameters:
    ///   - snapshot: 主窗口快照；nil 表示没有可跟踪的主窗口，或遮罩当前不应生效。
    ///   - maskIsOnActiveSpace: 遮罩窗口此刻是否位于当前桌面。
    public static func decide(snapshot: WindowSnapshot?, layout: ListColumnLayout, maskIsOnActiveSpace: Bool) -> MaskDecision {
        guard let snapshot else { return .hide }
        switch snapshot.presence {
        case .closed:
            return .hide
        case .onOtherSpace:
            // 遮罩还在当前桌面，说明是微信被移走了；否则两者一起留在微信所在的桌面，切回来时一起出现
            return maskIsOnActiveSpace ? .hide : .keep
        case .visible:
            guard let plan = plan(windowFrame: snapshot.frame, layout: layout, occluders: snapshot.occluders) else {
                return .hide
            }
            return .show(plan)
        }
    }
}
