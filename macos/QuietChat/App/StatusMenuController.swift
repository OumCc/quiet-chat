// 菜单栏图标与菜单：显示当前状态，提供授权入口、遮罩开关、校准和退出。
// 遮罩开关只在 M1 使用；M2 起改为"锁定 / 解锁"，关闭遮罩需要密码。

import AppKit

/// 菜单所需的状态与操作，由 AppDelegate 提供。
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var statusDescription: String { get }
    var needsAccessibilityPermission: Bool { get }
    var isMaskEnabled: Bool { get }
    var canCalibrate: Bool { get }
    func requestAccessibilityPermission()
    func toggleMask()
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

    /// 遮罩开关变化后更新图标；菜单内容在每次打开时重建，无需主动刷新。
    func updateIcon() {
        let enabled = delegate?.isMaskEnabled ?? true
        let image = NSImage(systemSymbolName: enabled ? "eye.slash" : "eye", accessibilityDescription: "QuietChat")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let delegate else { return }

        let status = NSMenuItem(title: delegate.statusDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if delegate.needsAccessibilityPermission {
            menu.addItem(makeItem("授予辅助功能权限…", #selector(requestPermission)))
        }

        menu.addItem(.separator())
        let toggle = makeItem("启用遮罩", #selector(toggleMask))
        toggle.state = delegate.isMaskEnabled ? .on : .off
        menu.addItem(toggle)
        let calibrate = makeItem("校准遮罩位置…", #selector(beginCalibration))
        calibrate.isEnabled = delegate.canCalibrate
        menu.addItem(calibrate)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 QuietChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func requestPermission() { delegate?.requestAccessibilityPermission() }

    @objc private func toggleMask() {
        delegate?.toggleMask()
        updateIcon()
    }

    @objc private func beginCalibration() { delegate?.beginCalibration() }
}
