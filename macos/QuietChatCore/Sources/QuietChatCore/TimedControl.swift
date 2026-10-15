// 定时强控：持久化偏好与运行期周期分离，截止时间仅使用包含睡眠的连续时钟。
// 校验和设置应用接受显式时刻；解锁成功不代表改变遮罩状态，由装配层落实。

import Foundation

/** 定时强控偏好；只保存开关和整数分钟数，非法分钟数回退 30。 */
public struct TimedControlSettings: Codable, Equatable, Sendable {
    /** 是否在下一次原密码成功解锁后开启固定周期。 */
    public let enabled: Bool
    /** 每轮分钟数，范围 1～1440。 */
    public let durationMinutes: Int
    /** 菜单预设，独立于是否启用和本轮剩余时间。 */
    public static let presets = [15, 30, 45, 60]
    /** 自定义分钟数范围。 */
    public static let durationRange = 1...1440
    /** 旧配置与首次运行使用关闭、30 分钟。 */
    public static let `default` = TimedControlSettings()

    /** 创建有效偏好；超出范围的分钟数使用默认值。 */
    public init(enabled: Bool = false, durationMinutes: Int = 30) {
        self.enabled = enabled
        self.durationMinutes = Self.durationRange.contains(durationMinutes) ? durationMinutes : 30
    }

    /** 字段独立回退；整个对象无效时由 AppConfig 回退，不丢弃其他配置。 */
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: (try? container.decode(Bool.self, forKey: .enabled)) ?? false,
            durationMinutes: (try? container.decode(Int.self, forKey: .durationMinutes)) ?? 30)
    }
}

/** 输入框展示时的解锁要求；提交时必须再次与运行期要求核对。 */
public enum UnlockRequirement: Equatable, Sendable {
    /** 校验原有默认或自定义密码。 */
    case password
    /** 只校验固定小写键盘序列。 */
    case keyboardSequence

    /** 明文提示与校验共用的固定序列，不进入配置或密码记录。 */
    public static let keyboardSequenceText = "qwertyuiopasdfghjklzxcvbnm"
}

/** 解锁校验结果；要求变更时应清空旧草稿，不能把它当成新要求下的输入。 */
public enum UnlockAttemptResult: Equatable, Sendable {
    /** 校验通过，调用方可以解锁。 */
    case unlocked
    /** 当前要求下输入不匹配。 */
    case incorrect
    /** 输入框要求已经过期，需要刷新后重新输入。 */
    case requirementChanged
}

/** 单次应用运行中的固定周期；不遵循 Codable，退出即丢弃截止时间。 */
public struct TimedControlState: Equatable, Sendable {
    /** 本轮连续时钟截止时间；nil 表示等待下一次原密码成功解锁。 */
    public private(set) var deadline: ContinuousClock.Instant?

    /** 启动时没有活动周期，即使持久化偏好已经启用。 */
    public init() {}

    /** 按提交时刻决定要求，恰好到期即恢复原密码。 */
    public func requirement(at now: ContinuousClock.Instant) -> UnlockRequirement {
        remainingSeconds(at: now) > 0 ? .keyboardSequence : .password
    }

    /** 剩余秒向上取整，过期为零；显示与要求判断使用同一截止时间。 */
    public func remainingSeconds(at now: ContinuousClock.Instant) -> Int {
        guard let deadline, now < deadline else { return 0 }
        let components = now.duration(to: deadline).components
        return Int(components.seconds) + (components.attoseconds > 0 ? 1 : 0)
    }

    /** 校验要求快照和输入；只有成功的原密码解锁才启动新周期，失败不修改状态。 */
    public mutating func attemptUnlock(
        _ input: String, requirement submitted: UnlockRequirement, settings: TimedControlSettings,
        passwordRecord: PasswordRecord?, at now: ContinuousClock.Instant
    ) -> UnlockAttemptResult {
        let current = requirement(at: now)
        guard submitted == current else { return .requirementChanged }
        let valid = current == .keyboardSequence
            ? input == UnlockRequirement.keyboardSequenceText
            : PasswordVerifier.verify(input, against: passwordRecord)
        guard valid else { return .incorrect }
        if current == .password, settings.enabled {
            deadline = now.advanced(by: .seconds(settings.durationMinutes * 60))
        }
        return .unlocked
    }

    /** 成功保存后应用偏好；活动周期改时长从此刻重计，关闭清除，其他时候只等待触发。 */
    public mutating func applySettings(
        _ settings: TimedControlSettings, replacing previous: TimedControlSettings,
        at now: ContinuousClock.Instant
    ) {
        guard settings != previous else { return }
        if settings.enabled, previous.enabled, requirement(at: now) == .keyboardSequence {
            deadline = now.advanced(by: .seconds(settings.durationMinutes * 60))
        } else {
            deadline = nil
        }
    }

    /** 清理自然到期的周期；不改变偏好或锁定状态。 */
    public mutating func expireIfNeeded(at now: ContinuousClock.Instant) {
        if let deadline, now >= deadline { self.deadline = nil }
    }
}
