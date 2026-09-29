// 遮罩控制：把微信主窗口快照交给 MaskPlanner 决策，再落实到遮罩面板的位置、洞和可见性；并管理密码输入和校准流程。
// 显示规则见 docs/architecture.md「显示规则」；锁定状态由调用方决定，这里只负责执行决策和坐标换算。

import AppKit
import QuietChatCore

@MainActor
final class MaskController {
    enum Mode {
        case masking
        case calibrating
    }

    /// 列表栏布局（校准结果）。
    var layout: ListColumnLayout = .default
    /// 是否锁定：锁定时显示遮罩和密码框，解锁后收起。
    var isLocked = true {
        didSet {
            guard isLocked != oldValue else { return }
            // 校准时遮罩是半透明的，锁定时必须放弃校准，否则隔着它能看到列表
            if isLocked { endCalibration(save: false) }
            view.resetPasswordField()
            render()
        }
    }
    /// 用户在遮罩上提交了密码；返回密码是否正确。正确时由调用方把 isLocked 置为 false。
    var onUnlockAttempt: ((String) -> Bool)?
    /// 密码框是否隐藏输入内容（用户上次的选择）。
    var hidesPasswordInput: Bool {
        get { view.hidesPasswordInput }
        set { view.hidesPasswordInput = newValue }
    }
    /// 用户切换了密码框的显示方式，需要记住；参数为是否隐藏输入。
    var onPasswordVisibilityChange: ((Bool) -> Void)?
    /// 校准完成、需要保存布局时回调。
    var onCalibrationFinished: ((ListColumnLayout) -> Void)?

    private(set) var mode: Mode = .masking
    private let panel = MaskPanel()
    private let view = MaskView()
    private var snapshot: WindowSnapshot?
    private var calibrationDraft: ListColumnLayout?
    private var lastRelocation = Date.distantPast
    private static let relocationInterval: TimeInterval = 0.5

    /// 遮罩是否正显示在当前桌面上。
    var isShowing: Bool { panel.isVisible && panel.isOnActiveSpace }

    /// 解锁状态下、主窗口在当前桌面可见时才能校准：校准时遮罩半透明，看得到列表，不能拿来绕过锁定。
    var canCalibrate: Bool { mode == .masking && !isLocked && snapshot?.presence == .visible }

    init() {
        panel.contentView = view
        view.onPasswordSubmit = { [weak self] password in
            guard let self else { return }
            if self.onUnlockAttempt?(password) != true {
                self.view.showWrongPassword()
            }
        }
        view.onPasswordVisibilityChange = { [weak self] hidden in self?.onPasswordVisibilityChange?(hidden) }
        view.onEdgeDrag = { [weak self] frame in self?.dragCalibration(to: frame) }
        view.onFinishCalibration = { [weak self] in self?.endCalibration(save: true) }
        view.onCancelCalibration = { [weak self] in self?.endCalibration(save: false) }
        view.onResetCalibration = { [weak self] in
            self?.calibrationDraft = .default
            self?.render()
        }
    }

    func update(snapshot: WindowSnapshot?) {
        self.snapshot = snapshot
        if mode == .calibrating, snapshot?.presence != .visible {
            // 窗口不见了，校准失去参照，直接放弃
            endCalibration(save: false)
        }
        render()
    }

    // MARK: - 校准

    func beginCalibration() {
        guard canCalibrate else { return }
        mode = .calibrating
        calibrationDraft = layout
        view.style = .calibration
        render()
    }

    private func dragCalibration(to cocoaFrame: NSRect) {
        guard mode == .calibrating, let snapshot else { return }
        let rect = GlobalCoordinates.flip(cocoaFrame, primaryScreenHeight: Self.primaryScreenHeight)
        calibrationDraft = ListColumnLayout(calibratedRect: rect, in: snapshot.frame)
        render()
    }

    private func endCalibration(save: Bool) {
        guard mode == .calibrating else { return }
        if save, let calibrationDraft {
            layout = calibrationDraft
            onCalibrationFinished?(calibrationDraft)
        }
        calibrationDraft = nil
        mode = .masking
        view.style = .mask
        render()
    }

    // MARK: - 显示

    private func render() {
        let calibrating = mode == .calibrating
        let decision = MaskPlanner.decide(
            snapshot: isLocked || calibrating ? snapshot : nil,
            layout: calibrating ? calibrationDraft ?? layout : layout,
            maskIsOnActiveSpace: panel.isOnActiveSpace)
        switch decision {
        case .show(let plan):
            show(plan, onAllSpaces: snapshot?.isOnAllSpaces == true)
        case .hide:
            hide()
        case .keep:
            break
        }
    }

    private func show(_ plan: MaskPlan, onAllSpaces: Bool) {
        if panel.joinsAllSpaces != onAllSpaces {
            panel.joinsAllSpaces = onAllSpaces
            Log.mask.notice("遮罩\(onAllSpaces ? "出现在所有桌面" : "只跟随微信所在桌面", privacy: .public)")
        }
        let frame = GlobalCoordinates.flip(plan.maskRect, primaryScreenHeight: Self.primaryScreenHeight)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        // 校准时需要看清整个区域，不开洞
        view.holes = mode == .calibrating ? [] : plan.holesInMaskCoordinates

        if !panel.isVisible {
            panel.orderFrontRegardless()
            Log.mask.notice("显示遮罩 \(String(describing: plan.maskRect), privacy: .public)")
        } else if !panel.isOnActiveSpace, Date().timeIntervalSince(lastRelocation) > Self.relocationInterval {
            // 微信出现在当前桌面、遮罩却留在别的桌面（微信被移过来、进入全屏）：移出再放回，放回时落到当前桌面。
            // 限制频率：万一系统没有移动面板，也不会每帧反复移出移入
            lastRelocation = Date()
            panel.orderOut(nil)
            panel.orderFrontRegardless()
            Log.mask.notice("遮罩移到当前桌面")
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        Log.mask.notice("收起遮罩")
    }

    /// 主显示器（全局坐标原点所在屏幕）的高度，用于 Quartz 与 Cocoa 坐标互转。
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}
