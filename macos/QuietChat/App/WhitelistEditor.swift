// 白名单编辑窗口：每行填一个聊天名称，保存时整理后交给调用方写入配置。
// 只在快捷入口方式且已解锁时由菜单打开；进入锁定或切回整块遮挡时，调用方用 close() 关掉它，未保存的修改丢弃。
// 名称是用户填写的聊天名，不写入日志。

import AppKit
import QuietChatCore
import SwiftUI

@MainActor
final class WhitelistEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// 打开编辑窗口；已经打开时只把它带到最前面。
    /// - Parameter onSave: 用户点「保存」时回调，参数是整理过的名单（见 `ChatWhitelist.normalized`）；取消或关闭窗口不回调。
    func show(whitelist: [String], onSave: @escaping ([String]) -> Void) {
        if window == nil {
            let view = WhitelistEditorView(
                text: whitelist.joined(separator: "\n"),
                onSave: { [weak self] text in
                    onSave(ChatWhitelist.normalized(text.components(separatedBy: .newlines)))
                    self?.close()
                },
                onCancel: { [weak self] in self?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "编辑白名单"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // 菜单栏应用平时不在前台，先激活，窗口才会出现在最前面并接收键盘输入
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关闭窗口，丢弃未保存的修改；窗口没有打开时什么都不做。
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct WhitelistEditorView: View {
    @State private var text: String
    private let onSave: (String) -> Void
    private let onCancel: () -> Void

    init(text: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每行填写完整搜索名称，有备注请填完整备注。普通聊天需能通过搜索回车直接打开；文件传输助手填词后请手动点击微信「功能」卡片。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
