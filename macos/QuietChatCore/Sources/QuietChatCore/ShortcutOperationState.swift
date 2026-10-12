// 快捷操作的串行状态，只管理编号和忙碌约束；不发送事件或管理系统焦点。

/** 同一实例一次只允许一个操作；取消后的旧完成回调不能影响新操作。 */
public struct ShortcutOperationState: Sendable {
    private var lastID: UInt64 = 0
    /** 当前操作编号；nil 表示待机。 */
    public private(set) var activeID: UInt64?
    /** 是否已有操作占用入口。 */
    public var isBusy: Bool { activeID != nil }

    /** 创建待机状态。 */
    public init() {}

    /** 开始新操作并返回递增编号；忙碌时拒绝，不排队。 */
    public mutating func begin() -> UInt64? {
        guard !isBusy else { return nil }
        lastID += 1
        activeID = lastID
        return lastID
    }

    /** 核对异步回调是否仍属于当前操作。 */
    public func isCurrent(_ id: UInt64) -> Bool { activeID == id }

    /** 取消当前操作，使其后续回调立即失效。 */
    public mutating func cancel() { activeID = nil }

    /** 仅完成当前编号；旧回调返回 false 且保留新操作。 */
    @discardableResult
    public mutating func finish(_ id: UInt64) -> Bool {
        guard isCurrent(id) else { return false }
        activeID = nil
        return true
    }
}
