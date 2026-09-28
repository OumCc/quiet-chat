// 应用入口：以菜单栏常驻应用启动（Info.plist 中 LSUIElement = YES，没有 Dock 图标），具体装配交给 AppDelegate。

import AppKit

@main
@MainActor
enum QuietChatApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication.delegate 是弱引用，要保证 delegate 活到 run() 返回
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
