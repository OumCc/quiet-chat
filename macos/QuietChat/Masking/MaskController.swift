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

    /// 列表栏布局（当前遮挡方式的校准结果）。
    var layout: ListColumnLayout = .default
    /// 密码框的位置：快捷入口在底部，强控时自动扩大底部空间。
    var lockControlsPlacement: MaskView.LockControlsPlacement {
        get { view.lockControlsPlacement }
        set { view.lockControlsPlacement = newValue }
    }
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
    /** 提交内容和展示时要求；要求过期时只刷新，不把旧草稿作为新密码验证。 */
    var onUnlockAttempt: ((String, UnlockRequirement) -> UnlockAttemptResult)?
    /** 同步强控提示，重复刷新不影响输入草稿。 */
    func updateTimedControl(requirement: UnlockRequirement, remainingSeconds: Int) {
        view.updateTimedControl(requirement: requirement, remainingSeconds: remainingSeconds)
    }
    /** 用户点击密码框时转交取消通知，不读取或修改密码草稿。 */
    var onPasswordFocus: (() -> Void)?
    /// 密码框是否隐藏输入内容（用户上次的选择）。
    var hidesPasswordInput: Bool {
        get { view.hidesPasswordInput }
        set { view.hidesPasswordInput = newValue }
    }
    /// 用户切换了密码框的显示方式，需要记住；参数为是否隐藏输入。
    var onPasswordVisibilityChange: ((Bool) -> Void)?
    /** 是否采用快捷入口布局；按钮只在锁定且不校准时出现。 */
    var usesShortcuts = false { didSet { if usesShortcuts != oldValue { render() } } }
    /** 按配置顺序传给视图的完整搜索名称。 */
    var shortcutNames: [String] {
        get { view.shortcutNames }
        set { view.shortcutNames = newValue }
    }
    /** 静态入口点击，模式与名单核对由装配层负责。 */
    var onShortcut: ((String) -> Void)?
    /** 仅刷新快捷操作反馈，密码解锁不随忙碌状态禁用。 */
    func updateShortcutFeedback(isBusy: Bool, message: String?) {
        view.shortcutBusy = isBusy
        view.shortcutMessage = message
    }
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
        view.onPasswordFocus = { [weak self] in self?.onPasswordFocus?() }
        view.onPasswordSubmit = { [weak self] password, requirement in
            guard let self else { return }
            if self.onUnlockAttempt?(password, requirement) == .incorrect {
                self.view.showWrongPassword()
            }
        }
        view.onPasswordVisibilityChange = { [weak self] hidden in self?.onPasswordVisibilityChange?(hidden) }
        view.onShortcut = { [weak self] name in self?.onShortcut?(name) }
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

    /** 向微信交接焦点，保留密码框草稿和面板显示状态。 */
    func releaseInputFocus() { view.releaseInputFocus() }

    // MARK: - 校准

    func beginCalibration() {
        guard canCalibrate else { return }
        mode = .calibrating
        calibrationDraft = layout
        view.style = .calibration
        render()
    }

    /// 放弃正在进行的校准，不保存；没有在校准时什么都不做。
    /// 切换遮挡方式时调用：两种方式各有一套布局，草稿是按原来那一套开始的。
    func cancelCalibration() {
        endCalibration(save: false)
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
        view.showsShortcuts = usesShortcuts && isLocked && !calibrating
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
