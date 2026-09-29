// 遮罩内容。
// - 遮挡模式：不透明底色、提示文字和密码框；洞（其他窗口压在微信之上的区域）保持全透明，点击会穿透到那些窗口。
//   密码框压到洞上时暂时隐藏，免得画到别的窗口上。密码框由明文框和隐藏输入框叠放实现，右侧按钮切换显示哪一个；
// - 校准模式：半透明蓝色，可拖动左、右、上三条边，中间是完成 / 恢复默认 / 取消按钮。
// 视图坐标系翻转（原点在左上、y 向下），与 Quartz 方向一致，洞的坐标可以直接使用。

import AppKit

final class MaskView: NSView {
    enum Style {
        case mask
        case calibration
    }

    private enum Edge {
        case left, right, top
    }

    var style: Style = .mask {
        didSet {
            guard style != oldValue else { return }
            calibrationControls.isHidden = style != .calibration
            updateLockControlsVisibility()
            needsDisplay = true
        }
    }

    /// 视图坐标下的洞。
    var holes: [CGRect] = [] {
        didSet {
            guard holes != oldValue else { return }
            updateLockControlsVisibility()
            needsDisplay = true
        }
    }

    /// 密码框是否隐藏输入内容。控制器按用户上次的选择设置；用户点右侧按钮时切换，并回调 onPasswordVisibilityChange。
    var hidesPasswordInput = false {
        didSet {
            if hidesPasswordInput != oldValue { applyPasswordVisibility() }
        }
    }

    /// 在密码框里按了回车。
    var onPasswordSubmit: ((String) -> Void)?
    /// 用户点了密码框右侧的按钮；参数为切换后的"是否隐藏输入"。
    var onPasswordVisibilityChange: ((Bool) -> Void)?
    /// 校准时拖动了边缘：参数为按拖动量调整后的面板外框（Cocoa 全局坐标），由控制器限制范围后回写。
    var onEdgeDrag: ((NSRect) -> Void)?
    var onFinishCalibration: (() -> Void)?
    var onCancelCalibration: (() -> Void)?
    var onResetCalibration: (() -> Void)?

    private static let edgeGrabWidth: CGFloat = 12
    private static let maskColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    }

    private let lockControls = NSStackView()
    private let plainPasswordField = FirstMouseRomanTextField()
    private let securePasswordField = FirstMouseSecureTextField()
    private let passwordVisibilityButton = FirstMouseButton()
    private let passwordError = NSTextField(labelWithString: "密码不对，再试一次")
    private let calibrationControls = NSStackView()
    private var dragEdge: Edge?
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpLockControls()
        setUpCalibrationControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // 面板不会激活本应用，第一次点击就要生效
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateLockControlsVisibility()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .mask:
            Self.maskColor.setFill()
            bounds.fill()
            // 放在密码框（上边缘在垂直中线）正上方
            drawCenteredText("聊天列表已隐藏", atY: bounds.midY - 32)
            // 最后清出洞，保证洞里连提示文字也不画
            NSColor.clear.setFill()
            for hole in holes {
                hole.fill(using: .copy)
            }
        case .calibration:
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            bounds.fill()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
            NSColor.systemBlue.setFill()
            for grip in gripRects() {
                NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private func drawCenteredText(_ text: String, atY y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        guard size.width < bounds.width - 16 else { return }
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: attributes)
    }

    /// 三条可拖动边上的把手。
    private func gripRects() -> [NSRect] {
        let length: CGFloat = 40
        let thickness: CGFloat = 5
        return [
            NSRect(x: 0, y: bounds.midY - length / 2, width: thickness, height: length),
            NSRect(x: bounds.maxX - thickness, y: bounds.midY - length / 2, width: thickness, height: length),
            NSRect(x: bounds.midX - length / 2, y: 0, width: length, height: thickness),
        ]
    }

    // MARK: - 校准拖动

    override func mouseDown(with event: NSEvent) {
        guard style == .calibration, let window else { return }
        dragEdge = edge(at: convert(event.locationInWindow, from: nil))
        // 拖动过程中面板本身在变，用屏幕坐标计算位移才稳定
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragEdge else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartMouse.x
        let dy = mouse.y - dragStartMouse.y
        var frame = dragStartFrame
        switch dragEdge {
        case .left:
            frame.origin.x += dx
            frame.size.width -= dx
        case .right:
            frame.size.width += dx
        case .top:
            // Cocoa 坐标 y 向上：向上拖 dy > 0，高度增加，底边不动
            frame.size.height += dy
        }
        onEdgeDrag?(frame)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdge = nil
    }

    private func edge(at point: NSPoint) -> Edge? {
        if point.x <= Self.edgeGrabWidth { return .left }
        if point.x >= bounds.width - Self.edgeGrabWidth { return .right }
        // 坐标系已翻转：y 小即靠近上边
        if point.y <= Self.edgeGrabWidth { return .top }
        return nil
    }

    // MARK: - 密码框

    /// 密码错误：清空输入并显示提示。
    func showWrongPassword() {
        clearPasswordFields()
        passwordError.isHidden = false
    }

    /// 回到初始状态（锁定或解锁时调用）：清空输入、收起提示、交还键盘焦点。
    func resetPasswordField() {
        clearPasswordFields()
        passwordError.isHidden = true
        window?.makeFirstResponder(nil)
    }

    private var passwordFields: [NSTextField] { [plainPasswordField, securePasswordField] }

    private func clearPasswordFields() {
        for field in passwordFields {
            field.stringValue = ""
        }
    }

    private func setUpLockControls() {
        for field in passwordFields {
            field.placeholderString = "输入密码解锁"
            field.alignment = .center
            field.target = self
            field.action = #selector(submitPassword(_:))
        }
        passwordVisibilityButton.isBordered = false
        passwordVisibilityButton.imagePosition = .imageOnly
        passwordVisibilityButton.contentTintColor = .secondaryLabelColor
        passwordVisibilityButton.target = self
        passwordVisibilityButton.action = #selector(togglePasswordVisibility)
        passwordVisibilityButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        passwordError.font = .systemFont(ofSize: 11)
        passwordError.textColor = .systemRed
        passwordError.isHidden = true

        // 两个输入框同一时间只显示一个（隐藏的不参与布局），按钮在右侧
        let fieldRow = NSStackView(views: [plainPasswordField, securePasswordField, passwordVisibilityButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 4

        lockControls.orientation = .vertical
        lockControls.spacing = 6
        lockControls.addArrangedSubview(fieldRow)
        lockControls.addArrangedSubview(passwordError)
        lockControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockControls)

        // 输入框的宽度约束引用了本视图，两端必须已在同一视图树中，所以放在 addSubview 之后激活
        var constraints = [
            lockControls.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockControls.topAnchor.constraint(equalTo: centerYAnchor),
        ]
        for field in passwordFields {
            // 默认宽 160，遮罩太窄时随之收窄（给右侧按钮留出位置）
            let preferredWidth = field.widthAnchor.constraint(equalToConstant: 160)
            preferredWidth.priority = .defaultHigh
            constraints += [preferredWidth, field.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -52)]
        }
        NSLayoutConstraint.activate(constraints)
        applyPasswordVisibility()
    }

    /// 按 hidesPasswordInput 切换显示哪个输入框；已输入的内容和正在输入的焦点跟着转过去。
    private func applyPasswordVisibility() {
        let shown: NSTextField = hidesPasswordInput ? securePasswordField : plainPasswordField
        let concealed: NSTextField = hidesPasswordInput ? plainPasswordField : securePasswordField
        let wasEditing = concealed.currentEditor() != nil
        shown.stringValue = concealed.stringValue
        // 先清空再移走焦点：若输入框在结束编辑时也发送动作，拿到的是空串，不会被当成提交
        concealed.stringValue = ""
        concealed.isHidden = true
        shown.isHidden = false

        let title = hidesPasswordInput ? "显示输入" : "隐藏输入"
        passwordVisibilityButton.image = NSImage(
            systemSymbolName: hidesPasswordInput ? "eye" : "eye.slash", accessibilityDescription: title)
        passwordVisibilityButton.toolTip = title

        if wasEditing {
            window?.makeFirstResponder(shown)
            // 光标放到末尾，而不是全选
            let end = (shown.stringValue as NSString).length
            shown.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func updateLockControlsVisibility() {
        let overlapsHole = holes.contains { $0.intersects(lockControls.frame) }
        lockControls.isHidden = style != .mask || overlapsHole
    }

    @objc private func submitPassword(_ sender: NSTextField) {
        let password = sender.stringValue
        guard !password.isEmpty else { return }
        onPasswordSubmit?(password)
    }

    @objc private func togglePasswordVisibility() {
        hidesPasswordInput.toggle()
        onPasswordVisibilityChange?(hidesPasswordInput)
    }

    // MARK: - 校准按钮

    private func setUpCalibrationControls() {
        let hint = NSTextField(wrappingLabelWithString: "拖动左、右、上三条边，\n对齐微信的聊天列表")
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 12)

        let done = FirstMouseButton(title: "完成", target: self, action: #selector(finish))
        let reset = FirstMouseButton(title: "恢复默认", target: self, action: #selector(reset))
        let cancel = FirstMouseButton(title: "取消", target: self, action: #selector(cancel))

        calibrationControls.orientation = .vertical
        calibrationControls.spacing = 8
        for view in [hint, done, reset, cancel] {
            calibrationControls.addArrangedSubview(view)
        }
        calibrationControls.setCustomSpacing(14, after: hint)
        calibrationControls.translatesAutoresizingMaskIntoConstraints = false
        calibrationControls.isHidden = true
        addSubview(calibrationControls)
        NSLayoutConstraint.activate([
            calibrationControls.centerXAnchor.constraint(equalTo: centerXAnchor),
            calibrationControls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func finish() { onFinishCalibration?() }
    @objc private func reset() { onResetCalibration?() }
    @objc private func cancel() { onCancelCalibration?() }
}

/// 本应用未激活时也响应第一次点击的按钮（遮罩所在面板不会激活本应用）。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 第一次点击就开始输入的隐藏输入框。系统会为它开启安全输入，中文输入法自动停用。
private final class FirstMouseSecureTextField: NSSecureTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 第一次点击就开始输入的明文密码框。
/// 明文框没有安全输入，中文输入法会把字母拼成候选词，所以获得焦点时只允许英文输入法。
private final class FirstMouseRomanTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return accepted
    }
}
