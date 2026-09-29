// 修改解锁密码的对话框：输入两次新密码，一致才返回。
// 只在解锁状态下提供（用户已经证明知道当前密码），所以不再询问旧密码。

import AppKit

@MainActor
enum PasswordChangeDialog {
    /// 弹出对话框；返回新密码，用户取消时返回 nil。
    static func run() -> String? {
        let newPassword = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 240, height: 24))
        newPassword.placeholderString = "新密码"
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        confirmation.placeholderString = "再输入一次"
        newPassword.nextKeyView = confirmation
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        fields.addSubview(newPassword)
        fields.addSubview(confirmation)

        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "修改解锁密码"
            alert.informativeText = problem ?? "以后在遮罩上用新密码解锁。忘了密码可以在菜单里选「恢复默认密码…」。"
            alert.accessoryView = fields
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = newPassword
            // 菜单栏应用平时不在前台，先激活，对话框才能接收键盘输入
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            if newPassword.stringValue.isEmpty {
                problem = "密码不能为空。"
            } else if newPassword.stringValue != confirmation.stringValue {
                problem = "两次输入不一致，请重新输入。"
                confirmation.stringValue = ""
            } else {
                return newPassword.stringValue
            }
        }
    }
}
