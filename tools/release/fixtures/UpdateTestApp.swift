// 隔离的安装验证宿主：运行真实 AppUpdateController，但不启动微信跟踪或申请辅助功能权限。
// 使用独立 bundle ID 和临时目录记录版本/偏好，避免影响用户正在使用的 QuietChat。

import AppKit
import QuietChatCore

@MainActor
final class UpdateTestDelegate: NSObject, NSApplicationDelegate {
    private let updates = AppUpdateController(preferences: UpdatePreferences())
    private var window: NSWindow!
    private var label: NSTextField!
    private var item: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        UserDefaults.standard.register(defaults: ["FixtureMarker": "保留测试配置"])
        if UserDefaults.standard.object(forKey: "PersistedFixtureMarker") == nil {
            UserDefaults.standard.set("保留测试配置", forKey: "PersistedFixtureMarker")
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "QuietChat 更新验证 · 构建 \(version)"
        let view = window.contentView!
        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 100, width: 440, height: 65)
        view.addSubview(label)
        for (title, action, x) in [
            ("检查更新", #selector(check), 20.0),
            ("切换自动检查", #selector(toggle), 165.0),
            ("退出测试", #selector(quit), 330.0),
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: x, y: 35, width: 130, height: 32)
            view.addSubview(button)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "更新测试"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updates.onChange = { [weak self] in self?.recordState() }
        updates.onUserInteraction = { [weak self] in self?.window.orderOut(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordState() }
        }
        updates.start()
        recordState()
        window.makeKeyAndOrderFront(nil)
    }

    private func recordState() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        let state: [String: Any] = [
            "build": version, "automaticChecks": updates.automaticallyChecksForUpdates,
            "availableVersion": updates.availableUpdateVersion ?? "",
            "marker": UserDefaults.standard.string(forKey: "PersistedFixtureMarker") ?? "",
        ]
        label.stringValue = "构建 \(version) · 自动检查 \(updates.automaticallyChecksForUpdates)\n\(updates.menuTitle)"
        item.button?.title = updates.availableUpdateVersion == nil ? "更新测试" : "更新测试 ●"
        if !window.isVisible, updates.canCheckForUpdates, NSApp.modalWindow == nil,
           !NSApp.windows.contains(where: { $0 !== window && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "FixtureStatePath") as? String,
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @objc private func check() { updates.checkForUpdates() }
    @objc private func toggle() { updates.toggleAutomaticChecks() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
@MainActor
enum UpdateTestApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = UpdateTestDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
