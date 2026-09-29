// 菜单栏图标与菜单：显示锁定状态，提供授权入口、立即锁定、修改密码、恢复默认密码、校准和退出。
// 解锁只能在遮罩上输入密码完成，菜单里没有解锁入口；修改密码和校准需要先解锁，恢复默认密码不受锁定限制。

import AppKit

/// 菜单所需的状态与操作，由 AppDelegate 提供。
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var statusDescription: String { get }
    var needsAccessibilityPermission: Bool { get }
    var isLocked: Bool { get }
    var canCalibrate: Bool { get }
    func requestAccessibilityPermission()
    func lockNow()
    func changePassword()
    func resetPassword()
    func beginCalibration()
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
            menu.addItem(makeDisabledItem("解锁后才能修改密码和校准"))
        }

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
    @objc private func lockNow() { delegate?.lockNow() }
    @objc private func changePassword() { delegate?.changePassword() }
    @objc private func resetPassword() { delegate?.resetPassword() }
    @objc private func beginCalibration() { delegate?.beginCalibration() }
}
