// 短生命周期键盘搜索：仅向已核对的微信主窗口发送事件，不读画面、剪贴板或聊天内容。

import AppKit
import ApplicationServices
import QuietChatCore

/** 执行可取消的键盘搜索；提速时序待本机实测，执行结束仅说明指令已发出，不确认聊天身份。 */
@MainActor
final class WeChatShortcutController {
    enum OperationError: String, Error {
        case eventUnavailable, permissionMissing
    }

    /** 仅反映当前任务是否占用入口，不表示聊天已打开。 */
    var isBusy: Bool { state.isBusy }
    /** 短反馈；普通聊天完成时清除，文件传输助手完成时提示手动选择。 */
    private(set) var message: String?
    /** 忙碌或反馈变化后刷新 UI，不要求重新聚焦任何窗口。 */
    var onChange: (() -> Void)?

    private var state = ShortcutOperationState()
    private var task: Task<Void, Never>?
    private var activeTracker: WeChatWindowTracker?
    private var activeTarget: WeChatWindowTracker.ShortcutTarget?
    private var hasConfirmedFocus = false
    private var startedAt = ContinuousClock.now

    /** 点击时已失去有效窗口也给出短反馈，不启动任务。 */
    func reportUnavailableTarget() {
        guard !isBusy else { return }
        startedAt = .now
        let permissionMissing = !AXIsProcessTrusted() || !CGPreflightPostEventAccess()
        message = permissionMissing ? Self.feedback(for: OperationError.permissionMissing) : "微信主窗口不可用"
        record(stage: "finished", errorCode: permissionMissing ? "permissionMissing" : "targetUnavailable")
        onChange?()
    }

    /** 接受已核对名单项并捕获时序快照；忙碌时拒绝，释放焦点后执行一次，不排队或重试。 */
    @discardableResult
    func start(name: String, timing: ShortcutTiming, tracker: WeChatWindowTracker, target: WeChatWindowTracker.ShortcutTarget,
               releaseFocus: @escaping () -> Void, isAllowed: @escaping () -> Bool) -> Bool {
        guard !isBusy, isAllowed() else { return false }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            message = Self.feedback(for: OperationError.permissionMissing)
            onChange?()
            return false
        }
        guard let id = state.begin() else { return false }
        startedAt = .now
        Log.shortcuts.notice("stage=started elapsed-ms=0 search-open-ms=\(timing.searchOpenMs, privacy: .public) select-all-ms=\(timing.selectAllMs, privacy: .public) results-ms=\(timing.resultsMs, privacy: .public)")
        activeTracker = tracker
        activeTarget = target
        hasConfirmedFocus = false
        message = name == "文件传输助手" ? "正在准备搜索…" : "正在打开…"
        task = Task { [weak self] in
            guard let self else { return }
            let mayContinue = { self.state.isCurrent(id) && isAllowed() }
            do {
                guard mayContinue() else { throw CancellationError() }
                releaseFocus()
                let result = try await self.execute(name: name, timing: timing, tracker: tracker, target: target, mayContinue: mayContinue)
                self.finish(id, message: result, errorCode: "none")
            } catch {
                let code = (error as? OperationError)?.rawValue
                    ?? (error as? WeChatWindowTracker.FocusError)?.rawValue ?? "cancelled"
                self.finish(id, message: Self.feedback(for: error), errorCode: code)
            }
        }
        onChange?()
        return state.isCurrent(id)
    }

    /** 先使编号失效再取消 Task；旧任务的清理不会覆盖后来的操作或反馈。 */
    func cancel(showFeedback: Bool = false) {
        guard state.isBusy || message != nil else { return }
        if state.isBusy { record(stage: "cancelled", errorCode: "cancelled") }
        state.cancel()
        task?.cancel()
        task = nil
        activeTracker = nil
        activeTarget = nil
        hasConfirmedFocus = false
        message = showFeedback ? "操作已取消" : nil
        onChange?()
    }

    /** 聚焦确认后，窗口或前台通知可立即停止任务；聚焦请求阶段仍由有界确认负责。 */
    func cancelIfTargetInvalid() {
        guard state.isBusy, hasConfirmedFocus, let activeTracker, let activeTarget else { return }
        do { try activeTracker.validateShortcutFocus(activeTarget) }
        catch { cancel(showFeedback: true) }
    }

    private func finish(_ id: UInt64, message: String?, errorCode: String) {
        guard state.finish(id) else { return }
        record(stage: "finished", errorCode: errorCode)
        task = nil
        activeTracker = nil
        activeTarget = nil
        hasConfirmedFocus = false
        self.message = message
        onChange?()
    }

    private static func feedback(for error: any Error) -> String {
        if error as? OperationError == .permissionMissing { return "需要辅助功能与键盘合成权限" }
        if error is CancellationError { return "操作已取消" }
        if let focus = error as? WeChatWindowTracker.FocusError {
            switch focus {
            case .foregroundChanged, .focusedWindowChanged: return "操作已取消"
            case .targetUnavailable: return "微信主窗口不可用"
            case .focusUnconfirmed: return "未能聚焦微信"
            }
        }
        return "无法发送搜索按键"
    }

    private func record(stage: String, errorCode: String = "none") {
        let duration = startedAt.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        Log.shortcuts.notice("stage=\(stage, privacy: .public) elapsed-ms=\(milliseconds) error=\(errorCode, privacy: .public)")
    }

    private func execute(name: String, timing: ShortcutTiming, tracker: WeChatWindowTracker, target: WeChatWindowTracker.ShortcutTarget,
                 mayContinue: () -> Bool) async throws -> String? {
        // 按本次快照使用分阶段时序；等待不能当作搜索控件就绪或聊天身份回执。
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw OperationError.permissionMissing }
        record(stage: "focusing")
        try await tracker.focusMainWindow(target, mayContinue: mayContinue)
        try validate(tracker: tracker, target: target, mayContinue: mayContinue)
        hasConfirmedFocus = true
        record(stage: "opening-search")
        try post(key: 3, flags: .maskCommand, tracker: tracker, target: target, mayContinue: mayContinue)
        try await wait(.milliseconds(timing.searchOpenMs), tracker: tracker, target: target, mayContinue: mayContinue)
        record(stage: "selecting-old-query")
        try post(key: 0, flags: .maskCommand, tracker: tracker, target: target, mayContinue: mayContinue)
        try await wait(.milliseconds(timing.selectAllMs), tracker: tracker, target: target, mayContinue: mayContinue)
        record(stage: "entering-name")
        try post(text: name, tracker: tracker, target: target, mayContinue: mayContinue)
        record(stage: "awaiting-results")
        try await wait(.milliseconds(timing.resultsMs), tracker: tracker, target: target, mayContinue: mayContinue)
        if name == "文件传输助手" {
            record(stage: "manual-selection")
            return "请在微信点击『功能』中的文件传输助手"
        }
        record(stage: "submitting")
        try post(key: 36, tracker: tracker, target: target, mayContinue: mayContinue)
        return nil
    }

    private func validate(tracker: WeChatWindowTracker, target: WeChatWindowTracker.ShortcutTarget,
                          mayContinue: () -> Bool) throws {
        try Task.checkCancellation()
        guard mayContinue() else { throw CancellationError() }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw OperationError.permissionMissing }
        try tracker.validateShortcutFocus(target)
    }

    private func wait(_ duration: Duration, tracker: WeChatWindowTracker,
                      target: WeChatWindowTracker.ShortcutTarget, mayContinue: () -> Bool) async throws {
        let deadline = ContinuousClock.now + duration
        repeat {
            try validate(tracker: tracker, target: target, mayContinue: mayContinue)
            try await Task.sleep(for: max(.zero, min(.milliseconds(50), ContinuousClock.now.duration(to: deadline))))
        } while ContinuousClock.now < deadline
        try validate(tracker: tracker, target: target, mayContinue: mayContinue)
    }

    private func post(key: CGKeyCode, flags: CGEventFlags = [], tracker: WeChatWindowTracker,
                      target: WeChatWindowTracker.ShortcutTarget, mayContinue: () -> Bool) throws {
        let pair = try events(key: key, flags: flags)
        try validate(tracker: tracker, target: target, mayContinue: mayContinue)
        post(pair, to: target.pid)
    }

    private func post(text: String, tracker: WeChatWindowTracker,
                      target: WeChatWindowTracker.ShortcutTarget, mayContinue: () -> Bool) throws {
        let units = Array(text.utf16)
        let pair = try events(key: 0)
        for event in pair {
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
        }
        try validate(tracker: tracker, target: target, mayContinue: mayContinue)
        post(pair, to: target.pid)
    }

    private func events(key: CGKeyCode, flags: CGEventFlags = []) throws -> [CGEvent] {
        try [true, false].map { down in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else {
                throw OperationError.eventUnavailable
            }
            event.flags = flags
            return event
        }
    }

    private func post(_ pair: [CGEvent], to pid: pid_t) {
        pair[0].postToPid(pid)
        // 同一组始终释放按键；无异步间隙，下一组重新核对身份。
        pair[1].postToPid(pid)
    }
}
