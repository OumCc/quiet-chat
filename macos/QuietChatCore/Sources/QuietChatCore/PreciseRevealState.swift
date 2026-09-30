// 精准遮挡的"先遮后露"状态：记录当前露出的带区，并保证过期的识别结果不会被采用。
// 列表内容一变化，已露出的带区立即清空；识别是异步的，结果要带着开始时拿到的编号回来，
// 期间内容又变化过（编号已经前进）的结果直接丢弃。规则见 docs/architecture.md「精准遮挡」。

import CoreGraphics

/// 精准遮挡当前露出哪些带区。
public struct PreciseRevealState: Equatable, Sendable {
    /// 当前露出的带区（微信主窗口坐标：原点在窗口外框左上角、y 向下）；为空表示整块遮住。
    public private(set) var revealedBands: [CGRect] = []
    private var generation = 0

    public init() {}

    /// 列表内容发生了变化：已露出的带区全部失效，此前开始的识别也随之过期。
    public mutating func contentChanged() {
        invalidate()
    }

    /// 开始一轮识别，返回这一轮的编号；识别完成时原样交给 `finishRecognition`。
    public func beginRecognition() -> Int {
        generation
    }

    /// 识别完成。编号仍是最新的才采用结果并返回 true；期间内容变化过或已经停止，则丢弃结果并返回 false。
    @discardableResult
    public mutating func finishRecognition(generation: Int, bands: [CGRect]) -> Bool {
        guard generation == self.generation else { return false }
        revealedBands = bands
        return true
    }

    /// 停止露出（解锁、窗口不可见、没有权限等）：清空带区，并让此前发出的编号全部失效。
    public mutating func reset() {
        invalidate()
    }

    private mutating func invalidate() {
        revealedBands = []
        generation += 1
    }
}
