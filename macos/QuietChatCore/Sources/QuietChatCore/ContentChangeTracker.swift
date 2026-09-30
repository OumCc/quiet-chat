// 定时读取列表画面时，判断每一张图意味着"内容变了"还是"画面已经稳定"。
// 每张图都与基准帧比较。基准帧是最近一次判为变化的那张图，而不是上一张：
// 这样缓慢累积的变化（例如滚动快停下时每次只动一点）迟早会越过阈值，不会被一点点放过去。
// 规则见 docs/architecture.md「精准遮挡」。

/// 画面变化与稳定的判断。
public struct ContentChangeTracker: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// 与基准帧不同，或者还没有基准帧：内容变了，已露出的行应当立即遮住。这张图成为新的基准帧。
        case changed
        /// 变化之后第一张与基准帧相同的图：画面已经稳定，可以用这张图识别。
        case settled
        /// 稳定之后仍与基准帧相同：没有新的情况。
        case unchanged
    }

    private var reference: ContentFingerprint?
    private var hasSettled = false

    public init() {}

    /// 处理新取到的一张图的指纹。
    public mutating func observe(_ fingerprint: ContentFingerprint) -> Verdict {
        guard let reference, !fingerprint.differs(from: reference) else {
            reference = fingerprint
            hasSettled = false
            return .changed
        }
        guard !hasSettled else { return .unchanged }
        hasSettled = true
        return .settled
    }

    /// 丢掉基准帧：下一张图按"变化"处理，之后重新判断稳定。
    /// 用在内容可能变了、但指纹未必看得出来的时候，或者需要用同一画面重新识别的时候。
    public mutating func invalidate() {
        reference = nil
        hasSettled = false
    }
}
