// 精准遮挡的流程控制：决定什么时候读取画面、什么时候识别、现在露出哪些行。
// 原则是"先遮后露"：列表内容一变化，已露出的行立即全部盖住；画面稳定、识别完成后再按新的结果露出。
// 只在"精准遮挡、已锁定、微信主窗口可见、有屏幕录制权限、白名单不为空"同时成立时读取画面，其余情况停止读取、整块遮住。
// 隐私：识别出的文字只用来和白名单比较，不保存、不写入日志。规则见 docs/architecture.md「精准遮挡」。

import AppKit
import QuietChatCore
import QuietChatDetection

@MainActor
final class PreciseRevealController {
    /// 没有权限或读取画面失败后，隔这么久再试一次。
    private static let retryInterval: TimeInterval = 5
    /// 一次识别最多等这么久；超时的结果丢弃。
    private static let recognitionTimeout: Duration = .seconds(2)
    /// 识别出错或超时后，隔这么久重试。
    private static let recognitionRetryDelay: Duration = .seconds(1)

    /// 露出的带区变化时回调，调用方据此重画遮罩。
    var onChange: (() -> Void)?

    /// 当前露出的带区（微信主窗口坐标：原点在窗口外框左上角、y 向下）；为空表示整块遮住。
    var revealedBands: [CGRect] { state.revealedBands }

    /// 最近一次读取画面失败了，还没有恢复。权限被收回或系统要求重新确认时就是这种情况，菜单据此提示授权。
    private(set) var isCaptureFailing = false

    private let capture = ListCapture()
    private var state = PreciseRevealState()
    /// 是否正在读取画面（包括正在启动）。
    private var isActive = false
    private var whitelist: [String] = []
    /// 列表栏在屏幕上的位置（Quartz 全局坐标），用来判断滚轮事件是不是落在列表上。
    private var columnFrameOnScreen: CGRect?
    private var scrollMonitor: Any?
    private var permissionGranted = false
    private var lastPermissionCheck = Date.distantPast
    private var retryNotBefore = Date.distantPast
    /// 每开始一轮识别加一；超时或被新一轮取代的识别，结果回来时编号对不上，直接丢弃。
    private var recognitionAttempt = 0
    private var timeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init() {
        capture.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// 根据最新状态启动、调整或停止读取画面。刷新遮罩时调用，可以很频繁。
    /// - Parameters:
    ///   - windowID: 微信主窗口在窗口服务器里的编号。
    ///   - layout: 精准遮挡使用的列表栏布局。
    func update(
        mode: MaskMode, isLocked: Bool, snapshot: WindowSnapshot?, windowID: CGWindowID?,
        layout: ListColumnLayout, whitelist: [String]
    ) {
        if whitelist != self.whitelist {
            self.whitelist = whitelist
            // 名单变了，之前的识别结果作废，用同一画面重新识别
            hideRevealedBands()
            capture.invalidate()
        }
        guard mode == .precise, isLocked, !whitelist.isEmpty, let snapshot, snapshot.presence == .visible,
              let windowID, let target = Self.target(windowID: windowID, windowFrame: snapshot.frame, layout: layout),
              hasPermission(), Date() >= retryNotBefore else {
            stop()
            return
        }
        columnFrameOnScreen = target.rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY)
        guard target != capture.target else { return }
        // 刚开始，或者窗口大小、列表栏位置、屏幕缩放变了：已露出的带区不再对应画面
        hideRevealedBands()
        isActive = true
        capture.setTarget(target)
        startScrollMonitor()
    }

    /// 屏幕录制权限可能刚发生变化（用户切换了遮挡方式或点了授权入口）：下次刷新时立即重新检查，不等重试间隔。
    func recheckPermission() {
        permissionGranted = false
        lastPermissionCheck = .distantPast
        retryNotBefore = .distantPast
    }

    // MARK: - 读取画面

    /// 列表栏在窗口里的区域，去掉底部始终遮住的一条；窗口太小、没有可露出的区域时返回 nil。
    private static func target(windowID: CGWindowID, windowFrame: CGRect, layout: ListColumnLayout) -> ListCapture.Target? {
        guard let column = layout.rect(in: CGRect(origin: .zero, size: windowFrame.size)),
              column.height > MaskPlanner.preciseReservedBottomHeight else { return nil }
        let rect = CGRect(
            x: column.minX, y: column.minY,
            width: column.width, height: column.height - MaskPlanner.preciseReservedBottomHeight)
        return ListCapture.Target(windowID: windowID, rect: rect, scale: backingScale(atWindowFrame: windowFrame))
    }

    /// 窗口所在屏幕每 pt 的像素数。窗口位置来自窗口服务器（Quartz 坐标），先换成 Cocoa 坐标再找屏幕。
    private static func backingScale(atWindowFrame frame: CGRect) -> CGFloat {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: frame.midX, y: primaryScreenHeight - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2
    }

    /// 缺少权限期间不必每次刷新都查询系统，隔一段时间查一次。
    private func hasPermission() -> Bool {
        if permissionGranted { return true }
        guard Date().timeIntervalSince(lastPermissionCheck) >= Self.retryInterval else { return false }
        lastPermissionCheck = Date()
        permissionGranted = ScreenRecordingPermission.isGranted
        return permissionGranted
    }

    private func stop() {
        guard isActive else { return }
        isActive = false
        capture.setTarget(nil)
        cancelPendingRecognition()
        stopScrollMonitor()
        columnFrameOnScreen = nil
        let hadRevealedBands = !state.revealedBands.isEmpty
        state.reset()
        if hadRevealedBands { onChange?() }
    }

    private func handle(_ event: ListCaptureEvent) {
        switch event {
        case .changed:
            isCaptureFailing = false
            cancelPendingRecognition()
            hideRevealedBands()
        case .settled(let frame):
            recognize(frame)
        case .failed:
            // 可能是权限被收回了：按没有权限处理，整块遮住，过一会儿再试
            isCaptureFailing = true
            permissionGranted = false
            lastPermissionCheck = Date()
            retryNotBefore = Date().addingTimeInterval(Self.retryInterval)
            stop()
        }
    }

    /// 让已露出的带区立即失效，正在进行的识别也随之过期。
    private func hideRevealedBands() {
        let hadRevealedBands = !state.revealedBands.isEmpty
        state.contentChanged()
        if hadRevealedBands { onChange?() }
    }

    // MARK: - 滚轮

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        // 遮住的区域上的滚轮事件被遮罩吃掉，到不了微信；能让列表滚动的只有落在露出行上的滚轮
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // 手指刚放上触控板时也会有滚轮事件，但没有滚动量
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
            MainActor.assumeIsolated {
                self?.listMayHaveScrolled()
            }
        }
    }

    private func stopScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    private func listMayHaveScrolled() {
        guard !state.revealedBands.isEmpty, let columnFrameOnScreen else { return }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        guard columnFrameOnScreen.contains(CGPoint(x: mouse.x, y: primaryScreenHeight - mouse.y)) else { return }
        // 不等下一次取图：滚动一开始就全部盖住，停下来之后再重新识别
        hideRevealedBands()
        capture.invalidate()
    }

    // MARK: - 识别

    private func recognize(_ frame: ListFrame) {
        cancelPendingRecognition()
        let generation = state.beginRecognition()
        let attempt = recognitionAttempt
        let whitelist = self.whitelist
        let origin = capture.target?.rect.origin ?? .zero
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            let bands = Self.whitelistedBands(in: frame, whitelist: whitelist)
            let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
            await self?.finishRecognition(
                attempt: attempt, generation: generation,
                // 识别结果是列表栏坐标，换成窗口坐标
                bands: bands?.map { $0.offsetBy(dx: origin.x, dy: origin.y) }, milliseconds: milliseconds)
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recognitionTimeout)
            guard !Task.isCancelled, let self, attempt == self.recognitionAttempt else { return }
            Log.capture.notice("识别超时，稍后重试")
            self.retryRecognitionLater()
        }
    }

    /// 识别出画面里属于白名单的行，返回它们的带区（列表栏坐标）；图片读不出或识别出错时返回 nil。
    private nonisolated static func whitelistedBands(in frame: ListFrame, whitelist: [String]) -> [CGRect]? {
        guard let image = frame.makeImage(),
              let boxes = try? TextRecognizer.recognize(image, scale: frame.scale, customWords: whitelist) else { return nil }
        return ListRowParser.parse(boxes, columnWidth: frame.pointSize.width)
            .filter { ChatNameMatcher.isWhitelisted($0.name, whitelist: whitelist) }
            .map(\.band)
    }

    private func finishRecognition(attempt: Int, generation: Int, bands: [CGRect]?, milliseconds: Int) {
        // 已经超时放弃，或者已经被新一轮识别取代
        guard attempt == recognitionAttempt else { return }
        timeoutTask?.cancel()
        guard let bands else {
            Log.capture.notice("识别失败，稍后重试")
            retryRecognitionLater()
            return
        }
        let accepted = state.finishRecognition(generation: generation, bands: bands)
        Log.capture.info(
            "识别完成：耗时 \(milliseconds) ms，匹配 \(bands.count) 行\(accepted ? "" : "，画面已变化，结果丢弃", privacy: .public)")
        if accepted, !bands.isEmpty { onChange?() }
    }

    /// 放弃这一轮识别，过一会儿让取图重新给出一张稳定的图。
    private func retryRecognitionLater() {
        cancelPendingRecognition()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recognitionRetryDelay)
            guard !Task.isCancelled else { return }
            self?.capture.invalidate()
        }
    }

    /// 让还没回来的识别结果作废，并取消等待中的超时和重试。
    private func cancelPendingRecognition() {
        recognitionAttempt += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        retryTask?.cancel()
        retryTask = nil
    }
}
