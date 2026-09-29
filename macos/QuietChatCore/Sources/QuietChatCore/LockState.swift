// 锁定状态：启动时锁定；输入正确密码才能解锁；
// 微信主窗口关闭（包括最小化、微信被隐藏或退出）时自动重新锁定，切换桌面不算。规则见 docs/architecture.md「锁定与解锁」。

/// 遮罩的锁定状态。
public struct LockState: Equatable, Sendable {
    public private(set) var isLocked = true

    public init() {}

    /// 密码校验通过后调用。
    public mutating func unlock() {
        isLocked = false
    }

    /// 手动锁定。
    public mutating func lock() {
        isLocked = true
    }

    /// 根据最新的主窗口快照决定是否自动锁定；快照为 nil 表示没有主窗口（窗口已销毁或微信已退出）。
    /// - Returns: 这次调用是否把状态从解锁变成了锁定。
    @discardableResult
    public mutating func autoLockIfNeeded(for snapshot: WindowSnapshot?) -> Bool {
        guard !isLocked else { return false }
        switch snapshot?.presence {
        case .visible, .onOtherSpace:
            return false
        case .closed, nil:
            isLocked = true
            return true
        }
    }
}
