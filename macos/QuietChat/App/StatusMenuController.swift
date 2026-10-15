// 菜单栏图标与菜单：显示锁定状态、版本与更新提醒，提供密码、校准、遮挡方式、白名单、速度、定时强控、外观和登录项。
// 解锁只能在遮罩上输入密码完成，菜单里没有解锁入口；修改密码、校准和编辑白名单需要先解锁，
// 恢复默认密码、切换遮挡方式、外观和开机自启动不受锁定限制。

import AppKit
import QuietChatCore

/// 菜单所需的状态与操作，由 AppDelegate 提供。
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var statusDescription: String { get }
    var needsAccessibilityPermission: Bool { get }
    var isLocked: Bool { get }
    var canCalibrate: Bool { get }
    var launchesAtLogin: Bool { get }
    var maskMode: MaskMode { get }
    /** 用户选择的外观偏好；跟随系统时也保持该选项勾选。 */
    var appearanceMode: AppearanceMode { get }
    /** 当前快捷入口时序；总和仅表示固定等待，不表示聊天已经打开。 */
    var shortcutTiming: ShortcutTiming { get }
    /** 持久化的强控开关及时长，与遮挡方式独立。 */
    var timedControlSettings: TimedControlSettings { get }
    /** 当前周期剩余秒数；零表示未开启或等待下次原密码成功。 */
    var timedControlRemainingSeconds: Int { get }
    /** 快捷入口方式且已解锁时才能编辑白名单。 */
    var canEditWhitelist: Bool { get }
    /** 下载忙碌时禁用检查；已有提醒可通过检查动作唤回标准窗口。 */
    var canCheckForUpdates: Bool { get }
    /** Sparkle 保存的检查选择；与是否允许后台安装无关。 */
    var automaticallyChecksForUpdates: Bool { get }
    /** 尚未得到用户关注的后台更新，用于图标标记和菜单标题。 */
    var availableUpdateVersion: String? { get }
    /** 用户主动检查或关注已有更新，安装仍由标准窗口征求确认。 */
    func checkForUpdates()
    /** 切换并持久化自动检查选择，不触发静默安装。 */
    func toggleAutomaticUpdateChecks()
    /** 手动下载安装包入口，用于系统或网络阻止自动更新时。 */
    func openUpdateDownloads()
    /** 菜单接管输入时停止未完成搜索，不改变锁定状态或方式。 */
    func prepareToOpenStatusMenu()
    func requestAccessibilityPermission()
    func selectMaskMode(_ mode: MaskMode)
    /** 切换整个应用的外观并保存偏好，锁定时也可调用。 */
    func selectAppearanceMode(_ mode: AppearanceMode)
    /** 修改并保存后续搜索时序；先取消旧操作，不主动发起搜索，锁定时也可调用。 */
    func selectShortcutTiming(_ timing: ShortcutTiming)
    /** 更改强控偏好；活动周期需要独立手输确认，保存成功后才生效。 */
    func selectTimedControl(_ settings: TimedControlSettings)
    func editWhitelist()
    func lockNow()
    func changePassword()
    func resetPassword()
    func beginCalibration()
    func toggleLaunchAtLogin()
}

/** 重建状态菜单与响应速度入口；参数选择交给 delegate，搜索始终由白名单按钮发起。 */
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var delegate: (any StatusMenuDelegate)?

    private enum TimingStage: Int, CaseIterable {
        case searchOpen, selectAll, results

        var title: String {
            switch self {
            case .searchOpen: "打开搜索"
            case .selectAll: "全选旧搜索词"
            case .results: "等待搜到结果"
            }
        }

        var maximum: Int {
            switch self {
            case .searchOpen: ShortcutTiming.searchOpenRange.upperBound
            case .selectAll: ShortcutTiming.selectAllRange.upperBound
            case .results: ShortcutTiming.resultsRange.upperBound
            }
        }

        var presets: [Int] {
            switch self {
            case .searchOpen: [0, 75]
            case .selectAll: [0, 25]
            case .results: [0, 250]
            }
        }

        func value(in timing: ShortcutTiming) -> Int {
            switch self {
            case .searchOpen: timing.searchOpenMs
            case .selectAll: timing.selectAllMs
            case .results: timing.resultsMs
            }
        }

        func replacing(_ milliseconds: Int, in timing: ShortcutTiming) -> ShortcutTiming {
            switch self {
            case .searchOpen:
                ShortcutTiming(searchOpenMs: milliseconds, selectAllMs: timing.selectAllMs, resultsMs: timing.resultsMs)
            case .selectAll:
                ShortcutTiming(searchOpenMs: timing.searchOpenMs, selectAllMs: milliseconds, resultsMs: timing.resultsMs)
            case .results:
                ShortcutTiming(searchOpenMs: timing.searchOpenMs, selectAllMs: timing.selectAllMs, resultsMs: milliseconds)
            }
        }
    }

    init(delegate: any StatusMenuDelegate) {
        self.delegate = delegate
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    /** 同步锁定图标与更新圆点；菜单内容在每次打开时重建。 */
    func updateIcon() {
        let locked = delegate?.isLocked ?? true
        let base = NSImage(named: locked ? "MenuBarLocked" : "MenuBarUnlocked")
        let version = delegate?.availableUpdateVersion
        let image: NSImage?
        if let base, version != nil {
            image = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect.insetBy(dx: 1, dy: 1))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 4, height: 4)).fill()
                return true
            }
        } else {
            image = base?.copy() as? NSImage
        }
        image?.isTemplate = true
        let status = locked ? "QuietChat 已锁定" : "QuietChat 已解锁"
        image?.accessibilityDescription = version.map { "\(status)，新版本 \($0) 可用" } ?? status
        statusItem.button?.image = image
        statusItem.button?.toolTip = image?.accessibilityDescription
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.appearance = NSApp.appearance
        menu.removeAllItems()
        guard let delegate else { return }

        menu.addItem(makeDisabledItem(delegate.statusDescription))
        if delegate.needsAccessibilityPermission {
            menu.addItem(makeItem("授予辅助功能权限…", #selector(requestPermission)))
        }

        menu.addItem(.separator())
        let unlocked = !delegate.isLocked
        let lock = makeItem("立即锁定", #selector(lockNow))
        lock.isEnabled = unlocked
        menu.addItem(lock)
        let password = makeItem("修改密码…", #selector(changePassword))
        password.isEnabled = unlocked
        menu.addItem(password)
        menu.addItem(makeItem("恢复默认密码…", #selector(resetPassword)))
        let calibrate = makeItem("校准遮罩位置…", #selector(beginCalibration))
        calibrate.isEnabled = delegate.canCalibrate
        menu.addItem(calibrate)
        if delegate.isLocked {
            menu.addItem(makeDisabledItem("解锁后才能修改密码、校准和编辑白名单"))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "遮挡方式"))
        let fullMask = makeItem("整块遮挡", #selector(selectFullMask))
        fullMask.state = delegate.maskMode == .full ? .on : .off
        menu.addItem(fullMask)
        let shortcutMask = makeItem("白名单快捷入口", #selector(selectShortcutMask))
        shortcutMask.state = delegate.maskMode == .shortcuts ? .on : .off
        menu.addItem(shortcutMask)
        let whitelist = makeItem("编辑白名单…", #selector(editWhitelist))
        whitelist.isEnabled = delegate.canEditWhitelist
        menu.addItem(whitelist)
        let timing = makeShortcutTimingItem(delegate.shortcutTiming)
        timing.isEnabled = delegate.maskMode == .shortcuts
        menu.addItem(timing)

        menu.addItem(.separator())
        menu.addItem(makeTimedControlItem(delegate.timedControlSettings, remainingSeconds: delegate.timedControlRemainingSeconds))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "外观"))
        let systemAppearance = makeItem("跟随系统", #selector(selectSystemAppearance))
        systemAppearance.state = delegate.appearanceMode == .system ? .on : .off
        menu.addItem(systemAppearance)
        let lightAppearance = makeItem("浅色模式", #selector(selectLightAppearance))
        lightAppearance.state = delegate.appearanceMode == .light ? .on : .off
        menu.addItem(lightAppearance)
        let darkAppearance = makeItem("深色模式", #selector(selectDarkAppearance))
        darkAppearance.state = delegate.appearanceMode == .dark ? .on : .off
        menu.addItem(darkAppearance)

        menu.addItem(.separator())
        let launchAtLogin = makeItem("开机自启动", #selector(toggleLaunchAtLogin))
        launchAtLogin.state = delegate.launchesAtLogin ? .on : .off
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        menu.addItem(makeDisabledItem("当前版本：\(version)"))
        let updateTitle = delegate.availableUpdateVersion.map { "安装更新 v\($0)…" } ?? "检查更新…"
        let check = makeItem(updateTitle, #selector(checkForUpdates))
        check.isEnabled = delegate.canCheckForUpdates
        menu.addItem(check)
        let automaticChecks = makeItem("自动检查更新", #selector(toggleAutomaticUpdateChecks))
        automaticChecks.state = delegate.automaticallyChecksForUpdates ? .on : .off
        menu.addItem(automaticChecks)
        menu.addItem(makeItem("下载安装包…", #selector(openUpdateDownloads)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 QuietChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        delegate?.prepareToOpenStatusMenu()
    }

    private func makeTimedControlItem(_ settings: TimedControlSettings, remainingSeconds: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "定时强控", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.autoenablesItems = false
        let toggle = makeItem("开启定时强控", #selector(toggleTimedControl))
        toggle.state = settings.enabled ? .on : .off
        menu.addItem(toggle)
        let status: String
        if !settings.enabled { status = "已关闭" }
        else if remainingSeconds > 0 {
            status = String(format: "剩余 %02d:%02d · 再次解锁需手输 Q-M", remainingSeconds / 60, remainingSeconds % 60)
        } else { status = "等待下一次原密码成功解锁后计时" }
        menu.addItem(makeDisabledItem(status))
        menu.addItem(.separator())
        for minutes in TimedControlSettings.presets {
            let preset = makeItem("\(minutes) 分钟", #selector(selectTimedControlPreset(_:)))
            preset.tag = minutes
            preset.state = settings.durationMinutes == minutes ? .on : .off
            menu.addItem(preset)
        }
        let isCustom = !TimedControlSettings.presets.contains(settings.durationMinutes)
        let custom = makeItem(isCustom ? "自定义（\(settings.durationMinutes) 分钟）…" : "自定义…",
                              #selector(customizeTimedControl))
        custom.state = isCustom ? .on : .off
        menu.addItem(custom)
        item.submenu = menu
        return item
    }

    private func promptTimedControlDuration(current: Int) -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = String(current)
        field.setAccessibilityLabel("定时强控时长（分钟）")
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "自定义定时强控时长"
            alert.informativeText = problem ?? "输入 1～1440 之间的整数，单位为分钟。"
            alert.accessoryView = field
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            NSApp.activate()
            field.selectText(nil)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let minutes = Int(input), TimedControlSettings.durationRange.contains(minutes) else {
                problem = "请输入 1～1440 之间的整数分钟值。"
                continue
            }
            return minutes
        }
    }

    private func makeShortcutTimingItem(_ timing: ShortcutTiming) -> NSMenuItem {
        let item = NSMenuItem(title: "白名单快捷入口响应速度", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.autoenablesItems = false
        menu.addItem(makeDisabledItem("固定等待合计：\(timing.totalMs) 毫秒"))
        menu.addItem(.separator())
        for stage in TimingStage.allCases {
            let current = stage.value(in: timing)
            let stageItem = NSMenuItem(title: "\(stage.title)：\(current) 毫秒", action: nil, keyEquivalent: "")
            let stageMenu = NSMenu(title: stage.title)
            stageMenu.autoenablesItems = false
            for milliseconds in stage.presets {
                let suffix = milliseconds == stage.value(in: .baseline) ? "（基准）" : ""
                let preset = makeItem("\(milliseconds) 毫秒\(suffix)", #selector(selectTimingPreset(_:)))
                preset.tag = stage.rawValue
                preset.representedObject = milliseconds
                preset.state = current == milliseconds ? .on : .off
                stageMenu.addItem(preset)
            }
            stageMenu.addItem(.separator())
            let isCustom = !stage.presets.contains(current)
            let custom = makeItem(isCustom ? "自定义（\(current) 毫秒）…" : "自定义…", #selector(customizeTiming(_:)))
            custom.tag = stage.rawValue
            custom.state = isCustom ? .on : .off
            stageMenu.addItem(custom)
            stageItem.submenu = stageMenu
            menu.addItem(stageItem)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("恢复基准（\(ShortcutTiming.baseline.totalMs) 毫秒）", #selector(restoreTimingBaseline)))
        item.submenu = menu
        return item
    }

    private func promptTiming(for stage: TimingStage, current: Int) -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = String(current)
        field.setAccessibilityLabel("等待时间（毫秒）")
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "自定义\(stage.title)时间"
            alert.informativeText = problem ?? "输入 0～\(stage.maximum) 之间的整数，单位为毫秒。"
            alert.accessoryView = field
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            NSApp.activate()
            field.selectText(nil)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let milliseconds = Int(input), (0...stage.maximum).contains(milliseconds) else {
                problem = "请输入 0～\(stage.maximum) 之间的整数毫秒值。"
                continue
            }
            return milliseconds
        }
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeDisabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func requestPermission() { delegate?.requestAccessibilityPermission() }
    @objc private func selectFullMask() { delegate?.selectMaskMode(.full) }
    @objc private func selectShortcutMask() { delegate?.selectMaskMode(.shortcuts) }
    @objc private func selectSystemAppearance() { delegate?.selectAppearanceMode(.system) }
    @objc private func selectLightAppearance() { delegate?.selectAppearanceMode(.light) }
    @objc private func selectDarkAppearance() { delegate?.selectAppearanceMode(.dark) }
    @objc private func toggleTimedControl() {
        guard let delegate else { return }
        let settings = delegate.timedControlSettings
        delegate.selectTimedControl(TimedControlSettings(enabled: !settings.enabled, durationMinutes: settings.durationMinutes))
    }
    @objc private func selectTimedControlPreset(_ sender: NSMenuItem) {
        guard let delegate, TimedControlSettings.presets.contains(sender.tag) else { return }
        delegate.selectTimedControl(TimedControlSettings(enabled: delegate.timedControlSettings.enabled, durationMinutes: sender.tag))
    }
    @objc private func customizeTimedControl() {
        guard let delegate, let minutes = promptTimedControlDuration(current: delegate.timedControlSettings.durationMinutes) else { return }
        delegate.selectTimedControl(TimedControlSettings(enabled: delegate.timedControlSettings.enabled, durationMinutes: minutes))
    }
    @objc private func selectTimingPreset(_ sender: NSMenuItem) {
        guard let delegate, delegate.maskMode == .shortcuts,
              let stage = TimingStage(rawValue: sender.tag), let milliseconds = sender.representedObject as? Int else { return }
        delegate.selectShortcutTiming(stage.replacing(milliseconds, in: delegate.shortcutTiming))
    }
    @objc private func customizeTiming(_ sender: NSMenuItem) {
        guard let delegate, delegate.maskMode == .shortcuts, let stage = TimingStage(rawValue: sender.tag),
              let milliseconds = promptTiming(for: stage, current: stage.value(in: delegate.shortcutTiming)) else { return }
        delegate.selectShortcutTiming(stage.replacing(milliseconds, in: delegate.shortcutTiming))
    }
    @objc private func restoreTimingBaseline() {
        guard let delegate, delegate.maskMode == .shortcuts else { return }
        delegate.selectShortcutTiming(.baseline)
    }
    @objc private func editWhitelist() { delegate?.editWhitelist() }
    @objc private func lockNow() { delegate?.lockNow() }
    @objc private func changePassword() { delegate?.changePassword() }
    @objc private func resetPassword() { delegate?.resetPassword() }
    @objc private func beginCalibration() { delegate?.beginCalibration() }
    @objc private func toggleLaunchAtLogin() { delegate?.toggleLaunchAtLogin() }
    @objc private func checkForUpdates() { delegate?.checkForUpdates() }
    @objc private func toggleAutomaticUpdateChecks() { delegate?.toggleAutomaticUpdateChecks() }
    @objc private func openUpdateDownloads() { delegate?.openUpdateDownloads() }
}
