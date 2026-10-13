// 更新偏好与升级授权提示策略：仅使用应用 UserDefaults，不改共享配置或替用户授予系统权限。

import Foundation

/** 读取 Sparkle 的同一份检查偏好，并记录已启动构建以避免重复升级提示。 */
@MainActor
public final class UpdatePreferences {
    /** Sparkle 持久化检查选择的键；缺失表示尚未作出选择。 */
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    private static let launchedBuildKey = "QuietChatLastLaunchedBuildVersion"
    private let defaults: UserDefaults

    /** 使用所属应用的偏好域；测试可注入独立 suite。 */
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /** nil 表示未询问；false 表示明确拒绝，不能在下一次启动覆盖。 */
    public var automaticCheckConsent: Bool? {
        guard defaults.object(forKey: Self.automaticChecksKey) != nil else { return nil }
        return defaults.bool(forKey: Self.automaticChecksKey)
    }

    /** 记录本次启动，返回是否从另一个已启动构建升级；首次安装不视为升级。 */
    public func recordLaunch(buildVersion: String) -> Bool {
        let previous = defaults.string(forKey: Self.launchedBuildKey)
        defaults.set(buildVersion, forKey: Self.launchedBuildKey)
        return previous != nil && previous != buildVersion
    }

    /** 只在升级且所需权限缺失时提示；整块遮挡不要求键盘合成访问。 */
    public static func needsPermissionReminder(
        buildChanged: Bool, hasAccessibility: Bool, needsKeyboardAccess: Bool, canPostEvents: Bool
    ) -> Bool {
        buildChanged && (!hasAccessibility || (needsKeyboardAccess && !canPostEvents))
    }
}

/** 菜单更新提醒；关注或会话结束即清理，安装决定仍由 Sparkle 管理。 */
public struct UpdateReminder: Sendable {
    /** 仍需用户关注的可用版本；nil 时显示普通检查入口。 */
    public private(set) var availableVersion: String?

    /** 初始没有提醒；版本只在后台更新需要用户关注时记录。 */
    public init() {}

    /** 后台发现版本后保留菜单提示，直到用户关注或会话结束。 */
    public mutating func show(version: String) {
        availableVersion = version
    }

    /** 用户关注、跳过、取消或会话出错时移除提示，避免旧版本标记残留。 */
    public mutating func clear() {
        availableVersion = nil
    }

    /** 点击入口会打开已有更新窗口；没有提醒时主动检查。 */
    public var menuTitle: String {
        availableVersion.map { "安装更新 v\($0)…" } ?? "检查更新…"
    }
}
