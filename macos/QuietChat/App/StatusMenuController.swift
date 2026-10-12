// 菜单栏图标与菜单：显示锁定状态，提供授权入口、立即锁定、修改密码、恢复默认密码、校准、遮挡方式、白名单、分阶段速度、外观、开机自启动和退出。
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
    /** 快捷入口方式且已解锁时才能编辑白名单。 */
    var canEditWhitelist: Bool { get }
    /** 菜单接管输入时停止未完成搜索，不改变锁定状态或方式。 */
    func prepareToOpenStatusMenu()
    func requestAccessibilityPermission()
    func selectMaskMode(_ mode: MaskMode)
    /** 切换整个应用的外观并保存偏好，锁定时也可调用。 */
    func selectAppearanceMode(_ mode: AppearanceMode)
    /** 修改并保存后续搜索时序；先取消旧操作，不主动发起搜索，锁定时也可调用。 */
    func selectShortcutTiming(_ timing: ShortcutTiming)
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

    /// 锁定状态变化后更新图标；菜单内容在每次打开时重建，无需主动刷新。
    func updateIcon() {
        let locked = delegate?.isLocked ?? true
        let image = NSImage(named: locked ? "MenuBarLocked" : "MenuBarUnlocked")
        image?.isTemplate = true
        image?.accessibilityDescription = locked ? "QuietChat 已锁定" : "QuietChat 已解锁"
        statusItem.button?.image = image
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
        menu.addItem(NSMenuItem(title: "退出 QuietChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        delegate?.prepareToOpenStatusMenu()
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
}
