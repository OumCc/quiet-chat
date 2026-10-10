// 菜单栏图标与菜单：显示锁定状态，提供授权入口、立即锁定、修改密码、恢复默认密码、校准、遮挡方式、白名单、外观、开机自启动和退出。
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
    /// 精准遮挡且已解锁时才能编辑白名单。
    var canEditWhitelist: Bool { get }
    /// 选了精准遮挡，但没有屏幕录制权限或读取画面失败。
    var needsScreenRecordingPermission: Bool { get }
    func requestAccessibilityPermission()
    func requestScreenRecordingPermission()
    func selectMaskMode(_ mode: MaskMode)
    /** 切换整个应用的外观并保存偏好，锁定时也可调用。 */
    func selectAppearanceMode(_ mode: AppearanceMode)
    func editWhitelist()
    func lockNow()
    func changePassword()
    func resetPassword()
    func beginCalibration()
    func toggleLaunchAtLogin()
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var delegate: (any StatusMenuDelegate)?

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
        if delegate.needsScreenRecordingPermission {
            menu.addItem(makeItem("授予屏幕录制权限…", #selector(requestScreenRecordingPermission)))
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
        let preciseMask = makeItem("精准遮挡（只露出白名单）", #selector(selectPreciseMask))
        preciseMask.state = delegate.maskMode == .precise ? .on : .off
        menu.addItem(preciseMask)
        let whitelist = makeItem("编辑白名单…", #selector(editWhitelist))
        whitelist.isEnabled = delegate.canEditWhitelist
        menu.addItem(whitelist)

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
    @objc private func requestScreenRecordingPermission() { delegate?.requestScreenRecordingPermission() }
    @objc private func selectFullMask() { delegate?.selectMaskMode(.full) }
    @objc private func selectPreciseMask() { delegate?.selectMaskMode(.precise) }
    @objc private func selectSystemAppearance() { delegate?.selectAppearanceMode(.system) }
    @objc private func selectLightAppearance() { delegate?.selectAppearanceMode(.light) }
    @objc private func selectDarkAppearance() { delegate?.selectAppearanceMode(.dark) }
    @objc private func editWhitelist() { delegate?.editWhitelist() }
    @objc private func lockNow() { delegate?.lockNow() }
    @objc private func changePassword() { delegate?.changePassword() }
    @objc private func resetPassword() { delegate?.resetPassword() }
    @objc private func beginCalibration() { delegate?.beginCalibration() }
    @objc private func toggleLaunchAtLogin() { delegate?.toggleLaunchAtLogin() }
}
