// 遮罩内容。
// - 遮挡模式：不透明底色 + 提示文字；洞（其他窗口压在微信之上的区域）保持全透明，点击会穿透到那些窗口；
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
            needsDisplay = true
        }
    }

    /// 视图坐标下的洞。
    var holes: [CGRect] = [] {
        didSet {
            if holes != oldValue { needsDisplay = true }
        }
    }

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

    private let calibrationControls = NSStackView()
    private var dragEdge: Edge?
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .mask:
            Self.maskColor.setFill()
            bounds.fill()
            drawCenteredText("聊天列表已隐藏", atY: bounds.height * 0.4)
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
