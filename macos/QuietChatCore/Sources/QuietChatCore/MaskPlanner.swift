// 遮罩决策：根据主窗口快照和列表栏布局，决定遮罩显示在哪里、要不要收起。
// 只为明确压在微信之上的窗口开洞；名单不参与几何计算，原聊天列表始终不透明。

import CoreGraphics

/// 一次遮罩的几何结果（Quartz 全局坐标）。
public struct MaskPlan: Equatable, Sendable {
    /// 遮罩覆盖的区域，即列表栏矩形。
    public var maskRect: CGRect
    /** 上层窗口与遮罩相交的区域，已裁剪到 maskRect 内。 */
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

/** 根据窗口快照和校准计算不透明遮罩，只为上层窗口让出区域。 */
public enum MaskPlanner {
    /** 计算遮罩和上层窗口洞，均取整点；列表栏与主窗口无交集时返回 nil。 */
    public static func plan(
        windowFrame: CGRect, layout: ListColumnLayout, occluders: [CGRect]
    ) -> MaskPlan? {
        guard let maskRect = layout.rect(in: windowFrame) else { return nil }
        let holes = occluders.compactMap { hole(for: $0, in: maskRect) }
        return MaskPlan(maskRect: maskRect, holes: holes)
    }

    /** 按可见性决定显示、收起或随其他桌面保持；snapshot 为 nil 时收起遮罩。 */
    public static func decide(
        snapshot: WindowSnapshot?, layout: ListColumnLayout, maskIsOnActiveSpace: Bool
    ) -> MaskDecision {
        guard let snapshot else { return .hide }
        switch snapshot.presence {
        case .closed:
            return .hide
        case .onOtherSpace:
            // 遮罩还在当前桌面，说明是微信被移走了；否则两者一起留在微信所在的桌面，切回来时一起出现
            return maskIsOnActiveSpace ? .hide : .keep
        case .visible:
            guard let plan = plan(
                windowFrame: snapshot.frame, layout: layout, occluders: snapshot.occluders)
            else {
                return .hide
            }
            return .show(plan)
        }
    }

    /// `rect` 落在 `bounds` 内的部分；没有交集时返回 nil。
    private static func hole(for rect: CGRect, in bounds: CGRect) -> CGRect? {
        let overlap = rect.intersection(bounds)
        guard !overlap.isNull, !overlap.isEmpty else { return nil }
        // 洞向外取整后再裁回范围内：上层窗口边缘不会压着一条没清干净的遮罩
        return overlap.integral.intersection(bounds)
    }
}
