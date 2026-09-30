// 读取微信主窗口里聊天列表的画面（ScreenCaptureKit），供精准遮挡判断内容变化和识别名称。
// 做法：每 0.2 秒取一张静帧，不开持续的截图流——系统会给被持续截取的窗口打上紫色的共享标记。
// 只截微信这一个窗口并裁到列表栏：图里没有本应用的遮罩，被别的窗口挡住的部分也能截到。
// 每张图算出指纹后与基准帧比较，向调用方报告"变化""稳定""失败"；判断变化和识别用的是同一张图。
// 隐私：画面只在内存里处理，不落盘、不联网；只保留最近一张图；日志只记录次数和错误码。
// 约定：窗口编号和列表栏矩形由调用方从窗口服务器取得后传入，不使用 ScreenCaptureKit 报告的窗口位置（实测出现过偏差）。

import CoreGraphics
import CoreVideo
import Foundation
import QuietChatCore
import ScreenCaptureKit

/// 一张列表栏的图。只在识别时才转换成图片。
struct ListFrame: @unchecked Sendable {
    // CVPixelBuffer 没有声明 Sendable；这里取到之后只读，不会再被修改
    fileprivate let pixelBuffer: CVPixelBuffer
    /// 图对应的列表栏区域大小（pt）。
    let pointSize: CGSize

    /// 图中每 pt 对应的像素数。
    var scale: CGFloat {
        pointSize.width > 0 ? CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / pointSize.width : 1
    }

    /// 转换成图片（复制一份像素）；缓冲区读不出来时返回 nil。
    func makeImage() -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        // 字节顺序为蓝、绿、红；第四个字节不是有效的透明度，忽略
        return CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
            .makeImage()
    }
}

enum ListCaptureEvent {
    /// 与基准帧不同：内容变了，或者刚开始取图、还没有基准帧。
    case changed
    /// 变化之后第一张与基准帧相同的图：画面已经稳定，可以用这张图识别。
    case settled(ListFrame)
    /// 找不到窗口或取图出错；取图已经停止，需要重新调用 `setTarget` 才会再开始。
    case failed
}

@MainActor
final class ListCapture: NSObject {
    struct Target: Equatable {
        /// 微信主窗口在窗口服务器里的编号。
        var windowID: CGWindowID
        /// 要读取的区域（微信主窗口坐标：原点在窗口外框左上角、y 向下，单位 pt）。
        var rect: CGRect
        /// 窗口所在屏幕每 pt 的像素数；按这个倍数取图，识别才看得清。
        var scale: CGFloat
    }

    /// 取图间隔。内容变化后最迟这么久开始下一次取图，加上取图耗时（实测约 40 ms）要在 0.3 秒内盖住。
    private static let pollInterval: TimeInterval = 0.2
    /// 一次取图最多等这么久。取图卡住时没人盯着列表的变化，必须按失败处理，让上层先整块遮住。
    private static let captureTimeout: TimeInterval = 1

    /// 事件回调，在主线程调用。
    var onEvent: ((ListCaptureEvent) -> Void)?

    private(set) var target: Target?
    /// 每次开始、停止或更换目标时加一；取图是异步的，回来时编号对不上的结果直接丢弃。
    private var session = 0
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var timer: Timer?
    /// 正在进行的这次取图的开始时间；没有取图在进行时为 nil。
    private var captureStartedAt: Date?
    /// 把每张图与基准帧比较，判断内容变了还是已经稳定。
    private var changeTracker = ContentChangeTracker()
    private var pollCount = 0
    private var changeCount = 0

    /// 设置要读取的目标；nil 表示停止。目标不变时什么都不做。
    func setTarget(_ newTarget: Target?) {
        guard newTarget != target else { return }
        let previous = target
        guard let newTarget else {
            stop()
            return
        }
        target = newTarget
        session += 1
        captureStartedAt = nil
        changeTracker.invalidate()
        configuration = Self.makeConfiguration(for: newTarget)
        if previous == nil {
            pollCount = 0
            changeCount = 0
            Log.capture.notice(
                "开始读取列表画面：\(Int(newTarget.rect.width))×\(Int(newTarget.rect.height)) pt，\(Int(newTarget.scale)) 倍")
        }
        if filter == nil || previous?.windowID != newTarget.windowID {
            prepareFilter(windowID: newTarget.windowID, session: session)
        }
    }

    /// 丢掉基准帧：下一张图按"变化"处理，之后重新判断稳定。
    /// 用在内容可能变了、但指纹未必看得出来的时候（滚轮），或者需要重新识别的时候（白名单改了、识别失败）。
    func invalidate() {
        changeTracker.invalidate()
    }

    private func stop() {
        guard target != nil else { return }
        Log.capture.notice("停止读取列表画面：取图 \(self.pollCount) 次，变化 \(self.changeCount) 次")
        tearDown()
    }

    private func tearDown() {
        session += 1
        target = nil
        timer?.invalidate()
        timer = nil
        filter = nil
        configuration = nil
        captureStartedAt = nil
        changeTracker.invalidate()
    }

    private func fail(_ reason: String) {
        Log.capture.error("读取列表画面失败：\(reason, privacy: .public)；已取图 \(self.pollCount) 次")
        tearDown()
        onEvent?(.failed)
    }

    // MARK: - 取图

    /// 按窗口编号找到要截的窗口，建好过滤器后开始定时取图。
    private func prepareFilter(windowID: CGWindowID, session: Int) {
        filter = nil
        timer?.invalidate()
        timer = nil
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard session == self.session else { return }
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    fail("找不到窗口")
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                startTimer()
            } catch {
                guard session == self.session else { return }
                fail(Self.describe(error))
            }
        }
    }

    private func startTimer() {
        let timer = Timer(
            timeInterval: Self.pollInterval, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        // common 模式：本应用的菜单打开时也继续取图，否则这期间列表变了发现不了
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    @objc private func poll() {
        if let captureStartedAt {
            // 上一次还没返回就跳过这一次；等得太久则放弃
            if Date().timeIntervalSince(captureStartedAt) > Self.captureTimeout {
                fail("取图超时")
            }
            return
        }
        guard let filter, let configuration, let target else { return }
        captureStartedAt = Date()
        let session = self.session
        let pointSize = target.rect.size
        let scale = max(1, Int(target.scale.rounded()))
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { [weak self] sampleBuffer, error in
            // 这里在系统的回调队列上：先算好指纹，再回主线程
            let captured = sampleBuffer?.imageBuffer.map { pixelBuffer in
                (ListFrame(pixelBuffer: pixelBuffer, pointSize: pointSize), Self.fingerprint(of: pixelBuffer, scale: scale))
            }
            let failure = captured == nil ? error.map(Self.describe) ?? "没有画面" : nil
            Task { @MainActor in
                self?.handle(captured: captured, failure: failure, session: session)
            }
        }
    }

    private func handle(captured: (frame: ListFrame, fingerprint: ContentFingerprint)?, failure: String?, session: Int) {
        guard session == self.session else { return }
        captureStartedAt = nil
        guard let captured else {
            fail(failure ?? "没有画面")
            return
        }
        pollCount += 1
        switch changeTracker.observe(captured.fingerprint) {
        case .changed:
            changeCount += 1
            onEvent?(.changed)
        case .settled:
            onEvent?(.settled(captured.frame))
        case .unchanged:
            break
        }
    }

    private static func makeConfiguration(for target: Target) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = target.rect
        configuration.width = Int((target.rect.width * target.scale).rounded())
        configuration.height = Int((target.rect.height * target.scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        // 单窗口截图默认带上阴影的留边，画面会整体偏移
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private nonisolated static func fingerprint(of pixelBuffer: CVPixelBuffer, scale: Int) -> ContentFingerprint {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return ContentFingerprint(
            bgra: UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddress(pixelBuffer), count: height * bytesPerRow),
            width: CVPixelBufferGetWidth(pixelBuffer), height: height, bytesPerRow: bytesPerRow, scale: scale)
    }

    /// 错误只记录域和代码，不记录可能带有窗口信息的描述。
    private nonisolated static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
