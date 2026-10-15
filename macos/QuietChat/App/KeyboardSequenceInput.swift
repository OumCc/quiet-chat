// 强控专用的明文手输控件与确认弹窗。
// 每个控件拥有独立 field editor，阻止粘贴、拖入、文本替换；不改变普通密码框的编辑器或偏好。

import AppKit
import QuietChatCore

/** 首次点击即可输入的强控框；只接收编辑器键盘输入，调用方负责最终序列校验。 */
@MainActor
final class KeyboardSequenceTextField: NSTextField {
    /** 用户点击输入时通知装配层取消未完成的快捷操作，不携带草稿内容。 */
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = KeyboardSequenceCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderString = "手动输入 Q-M 后回车"
        setAccessibilityLabel("定时强控固定序列，请手动输入")
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return accepted
    }
}

private final class KeyboardSequenceCell: NSTextFieldCell {
    private let editor = KeyboardSequenceFieldEditor()

    override init(textCell string: String) {
        super.init(textCell: string)
        usesSingleLineMode = true
        isScrollable = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/** 只让键盘事件产生单字符插入；拦截 AppKit 的粘贴板、拖放和多字符替换入口。 */
@MainActor
final class KeyboardSequenceFieldEditor: NSTextView {
    private let inputStorage: NSTextStorage

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let storage = NSTextStorage()
        inputStorage = storage
        // 独立编辑器需要显式建立文本系统；nil 容器不会创建可编辑的存储。
        let textContainer = container ?? NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                                      height: CGFloat.greatestFiniteMagnitude))
        if textContainer.layoutManager == nil {
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            layout.addTextContainer(textContainer)
        }
        super.init(frame: frameRect, textContainer: textContainer)
        isFieldEditor = true
        isRichText = false
        allowsUndo = true
        isAutomaticTextCompletionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = false
        enabledTextCheckingTypes = 0
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.characters, text.utf8.count == 1,
           let scalar = text.unicodeScalars.first, (32...126).contains(scalar.value) {
            // 逐键字符直接写入，绕开输入法异步提交及系统文本替换；编辑命令仍交给 AppKit。
            super.insertText(text, replacementRange: selectedRange())
        } else {
            super.keyDown(with: event)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {}

    override func paste(_ sender: Any?) {}
    override func pasteAsPlainText(_ sender: Any?) {}
    override func pasteAsRichText(_ sender: Any?) {}
    override func readSelection(from pboard: NSPasteboard) -> Bool { false }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:)),
            #selector(toggleAutomaticTextReplacement(_:))].contains(item.action) { return false }
        return super.validateUserInterfaceItem(item)
    }
}

/** 提前关闭或修改强控的独立确认；确认只授权当前设置操作，不触发遮罩解锁。 */
@MainActor
enum KeyboardSequenceDialog {
    /** 取消返回 false；输入正确或提交时周期已到期返回 true，错误时清空并继续。 */
    static func run(action: String, isRequired: () -> Bool) -> Bool {
        let field = KeyboardSequenceTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = action
            alert.informativeText = [problem, "手动输入以下固定小写序列后确认：", UnlockRequirement.keyboardSequenceText]
                .compactMap { $0 }.joined(separator: "\n")
            alert.accessoryView = field
            alert.addButton(withTitle: "确认")
            alert.addButton(withTitle: "取消")
            field.target = alert.buttons[0]
            field.action = #selector(NSButton.performClick(_:))
            alert.window.initialFirstResponder = field
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if !isRequired() || field.stringValue == UnlockRequirement.keyboardSequenceText { return true }
            field.stringValue = ""
            problem = "序列不对，请按 Q-M 顺序重新输入。"
        }
    }
}
