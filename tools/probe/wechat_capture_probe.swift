// 验证脚本：在真机上确认 ScreenCaptureKit 读取微信窗口画面时的实际行为，为精准遮挡的截图方案取证。
// 要回答的问题：单窗口截图时 sourceRect 是否生效；哪种取图方式会让微信窗口出现紫色的共享标记；
// 画面静止时是否不推送帧；悬停、选中在真实画面下会不会被判为内容变化；列表文字框的位置和省略号的识别写法。
// 边界：只读取画面并在内存中统计，不保存图片、不联网。报告里只有尺寸、帧状态、亮度、字数和标点，
// 不含任何识别出的文字。运行它的终端需要屏幕录制权限。
//
// 用法（在仓库根目录；与 Core 的两个源文件一起编译，测的是实际使用的算法）：
//   swiftc -O -parse-as-library -o /tmp/quietchat-capture-probe tools/probe/wechat_capture_probe.swift \
//     macos/QuietChatCore/Sources/QuietChatCore/ContentFingerprint.swift \
//     macos/QuietChatCore/Sources/QuietChatCore/ListRowParser.swift
//   /tmp/quietchat-capture-probe
// 运行前请解锁或退出 QuietChat，让微信的聊天列表露出来；过程中按提示观察和操作。
// 报告同时写到 /tmp/quietchat-capture-probe.txt。加 --self-check 只检查脚本自身的计算，不截图。

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Vision

// MARK: - 报告

final class Report: @unchecked Sendable {
    static let path = "/tmp/quietchat-capture-probe.txt"
    private let lock = NSLock()
    private var lines: [String] = []

    func line(_ text: String = "") {
        print(text)
        lock.lock()
        lines.append(text)
        lock.unlock()
    }

    /// 提问并把回答记入报告；只回车视为没有回答。
    func ask(_ question: String) -> String {
        print(question, terminator: " ")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        lock.lock()
        lines.append("\(question) \(answer.isEmpty ? "（未回答）" : answer)")
        lock.unlock()
        return answer
    }

    func save() {
        lock.lock()
        let text = lines.joined(separator: "\n") + "\n"
        lock.unlock()
        try? text.write(toFile: Self.path, atomically: true, encoding: .utf8)
    }
}

let report = Report()

func format(_ rect: CGRect?) -> String {
    guard let rect else { return "无" }
    return String(format: "(%.1f, %.1f, %.1f, %.1f)", rect.minX, rect.minY, rect.width, rect.height)
}

// MARK: - 画面

/// 一帧 BGRA 画面（第 0 行在顶部）。
struct Bitmap {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixels: [UInt8]

    /// 裁出一块区域（像素坐标），超出画面的部分被裁掉。
    func cropped(to rect: CGRect) -> Bitmap {
        let x0 = max(0, Int(rect.minX.rounded())), y0 = max(0, Int(rect.minY.rounded()))
        let x1 = min(width, Int(rect.maxX.rounded())), y1 = min(height, Int(rect.maxY.rounded()))
        let w = max(0, x1 - x0), h = max(0, y1 - y0)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let source = (y + y0) * bytesPerRow + x0 * 4
            out.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: pixels[source..<source + w * 4])
        }
        return Bitmap(width: w, height: h, bytesPerRow: w * 4, pixels: out)
    }

    /// 按比例缩小到能放进 size 的最大尺寸（最近邻取样），用来判断"是不是整窗被缩小了"。
    func scaledToFit(width targetWidth: Int, height targetHeight: Int) -> Bitmap {
        let scale = min(Double(targetWidth) / Double(width), Double(targetHeight) / Double(height))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let sy = min(height - 1, Int(Double(y) / scale))
            for x in 0..<w {
                let sx = min(width - 1, Int(Double(x) / scale))
                let source = sy * bytesPerRow + sx * 4
                out.replaceSubrange((y * w + x) * 4..<(y * w + x) * 4 + 4, with: pixels[source..<source + 4])
            }
        }
        return Bitmap(width: w, height: h, bytesPerRow: w * 4, pixels: out)
    }

    /// 与另一帧在左上角对齐的重叠区域内，蓝绿红三个通道的平均绝对差（0～255）；没有重叠时返回 nil。
    func meanDifference(from other: Bitmap, offsetX: Int = 0, offsetY: Int = 0) -> Double? {
        let w = min(width - offsetX, other.width), h = min(height - offsetY, other.height)
        guard w > 0, h > 0 else { return nil }
        var sum = 0
        for y in 0..<h {
            let a = (y + offsetY) * bytesPerRow + offsetX * 4, b = y * other.bytesPerRow
            for i in 0..<w * 4 where i % 4 != 3 {
                sum += abs(Int(pixels[a + i]) - Int(other.pixels[b + i]))
            }
        }
        return Double(sum) / Double(w * h * 3)
    }

    var fingerprint: ContentFingerprint {
        pixels.withUnsafeBytes { ContentFingerprint(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow) }
    }

    /// 每条（8 像素高）的底色亮度：把这一条横向分成 48 格，取各格平均亮度的中位数，与指纹的算法一致。
    var stripBackgrounds: [Double] {
        stride(from: 0, to: height, by: 8).map { top in
            let rows = top..<min(top + 8, height)
            let cells = (0..<48).map { cell -> Double in
                let start = cell * width / 48, end = max(start + 1, (cell + 1) * width / 48)
                var sum = 0
                for y in rows {
                    for x in start..<end {
                        let offset = y * bytesPerRow + x * 4
                        sum += 114 * Int(pixels[offset]) + 587 * Int(pixels[offset + 1]) + 299 * Int(pixels[offset + 2])
                    }
                }
                return Double(sum) / Double(1000 * rows.count * (end - start))
            }.sorted()
            return (cells[23] + cells[24]) / 2
        }
    }

    /// 最外一圈像素是否全部不透明：带阴影或留边的画面，边缘会是透明的。
    var hasOpaqueBorder: Bool {
        guard width > 0, height > 0 else { return false }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[y * bytesPerRow + x * 4 + 3] }
        return (0..<width).allSatisfy { alpha($0, 0) == 255 && alpha($0, height - 1) == 255 }
            && (0..<height).allSatisfy { alpha(0, $0) == 255 && alpha(width - 1, $0) == 255 }
    }
}

/// 流里的一帧：状态、随帧附带的几何信息，以及完整帧的画面。
struct Frame {
    var time: TimeInterval
    var status: SCFrameStatus
    var bitmap: Bitmap?
    var contentRect: CGRect?
    var contentScale: Double?
    var scaleFactor: Double?
    var boundingRect: CGRect?
    var screenRect: CGRect?
}

func name(of status: SCFrameStatus) -> String {
    switch status {
    case .complete: "complete"
    case .idle: "idle"
    case .blank: "blank"
    case .suspended: "suspended"
    case .started: "started"
    case .stopped: "stopped"
    @unknown default: "未知(\(status.rawValue))"
    }
}

final class FrameCollector: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let startTime = Date()
    private var collected: [Frame] = []
    private var stopError: (any Error)?
    /// 每收到一帧带画面的帧时回调（在截图队列上）。
    var onBitmap: ((Frame) -> Void)?

    var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return stopError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus)
        else { return }

        func rect(_ key: SCStreamFrameInfo) -> CGRect? {
            (attachments[key] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        var frame = Frame(
            time: Date().timeIntervalSince(startTime), status: status,
            contentRect: rect(.contentRect), contentScale: (attachments[.contentScale] as? NSNumber)?.doubleValue,
            scaleFactor: (attachments[.scaleFactor] as? NSNumber)?.doubleValue,
            boundingRect: rect(.boundingRect), screenRect: rect(.screenRect))
        if let buffer = sampleBuffer.imageBuffer {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let height = CVPixelBufferGetHeight(buffer), bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                frame.bitmap = Bitmap(
                    width: CVPixelBufferGetWidth(buffer), height: height, bytesPerRow: bytesPerRow,
                    pixels: [UInt8](UnsafeRawBufferPointer(start: base, count: height * bytesPerRow)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        lock.lock()
        collected.append(frame)
        lock.unlock()
        if frame.bitmap != nil { onBitmap?(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        stopError = error
        lock.unlock()
    }
}

func makeConfiguration(width: CGFloat, height: CGFloat, sourceRect: CGRect? = nil) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(width.rounded()))
    configuration.height = max(1, Int(height.rounded()))
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    // 单窗口截图默认带阴影的留边，画面会整体偏移
    configuration.ignoreShadowsSingleWindow = true
    if let sourceRect { configuration.sourceRect = sourceRect }
    return configuration
}

/// 开一条流，运行 `body` 期间持续收帧，结束后停掉。
func withStream(
    filter: SCContentFilter, configuration: SCStreamConfiguration, onBitmap: ((Frame) -> Void)? = nil,
    _ body: (FrameCollector) async throws -> Void
) async throws -> FrameCollector {
    let collector = FrameCollector()
    collector.onBitmap = onBitmap
    let stream = SCStream(filter: filter, configuration: configuration, delegate: collector)
    try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe.frames"))
    try await stream.startCapture()
    do {
        try await body(collector)
    } catch {
        try? await stream.stopCapture()
        throw error
    }
    try? await stream.stopCapture()
    return collector
}

func sleep(seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - 各步骤

/// 汇报一条流收到的帧：状态序列、完整帧的尺寸和附带的几何信息。返回最后一帧带画面的帧。
@discardableResult
func describe(_ collector: FrameCollector, expected: CGSize) -> Bitmap? {
    let frames = collector.frames
    if let error = collector.error {
        report.line("  流被系统停止：\((error as NSError).domain) \((error as NSError).code)")
    }
    let sequence = frames.prefix(12).map { name(of: $0.status) + ($0.bitmap == nil ? "" : "(有图)") }
    report.line("  帧状态（前 12 帧）：\(sequence.isEmpty ? "没有收到帧" : sequence.joined(separator: " "))")
    let counts = Dictionary(grouping: frames, by: { name(of: $0.status) }).mapValues(\.count)
    report.line("  共 \(frames.count) 帧：\(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))")
    guard let frame = frames.last(where: { $0.bitmap != nil }), let bitmap = frame.bitmap else {
        report.line("  没有带画面的帧")
        return nil
    }
    report.line("  画面 \(bitmap.width)×\(bitmap.height)（期望 \(Int(expected.width))×\(Int(expected.height))），"
        + "contentRect=\(format(frame.contentRect)) contentScale=\(frame.contentScale.map { String(format: "%.3f", $0) } ?? "无") "
        + "scaleFactor=\(frame.scaleFactor.map { String(format: "%.1f", $0) } ?? "无")")
    report.line("  boundingRect=\(format(frame.boundingRect)) screenRect=\(format(frame.screenRect)) 边缘不透明=\(bitmap.hasOpaqueBorder ? "是" : "否")")
    return bitmap
}

/// 判断裁剪是否生效：与整窗画面里的列表栏比较，再与"整窗缩小"比较。
func compareCrop(_ bitmap: Bitmap?, reference: Bitmap, column: CGRect) {
    guard let bitmap else { return }
    let expected = reference.cropped(to: column)
    let cropDifference = bitmap.meanDifference(from: expected) ?? expected.meanDifference(from: bitmap)
    let squeezed = reference.scaledToFit(width: bitmap.width, height: bitmap.height)
    // 缩小后的整窗可能贴左上角，也可能居中
    let centered = bitmap.meanDifference(
        from: squeezed, offsetX: (bitmap.width - squeezed.width) / 2, offsetY: (bitmap.height - squeezed.height) / 2)
    let squeezeDifference = [bitmap.meanDifference(from: squeezed), centered].compactMap { $0 }.min()
    func text(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "无法比较" }
    report.line("  与整窗画面里的列表栏的平均差 = \(text(cropDifference))；与整窗缩小后的平均差 = \(text(squeezeDifference))")
    let verdict: String
    if let cropDifference, cropDifference < 3 {
        verdict = "裁剪生效，得到的就是列表栏"
    } else if let squeezeDifference, squeezeDifference < 6 {
        verdict = "裁剪没有生效，得到的是缩小的整个窗口"
    } else {
        verdict = "两者都对不上，需要人工分析（画面可能在两次截图之间变了）"
    }
    report.line("  结论：\(verdict)")
}

func askAboutBadge(_ label: String) {
    _ = report.ask("  [\(label)] 截图进行中。微信窗口左上角的红绿灯有没有变成紫色图标？(y/n)")
}

/// 悬停、点击、滚动时指纹的变化：只记录条的序号、底色亮度和不同的格数。
final class ChangeLogger: @unchecked Sendable {
    private let column: CGRect
    private let lock = NSLock()
    private var previous: (bitmap: Bitmap, fingerprint: ContentFingerprint, backgrounds: [Double])?
    private var printed = 0

    init(column: CGRect) {
        self.column = column
    }

    func handle(_ frame: Frame) {
        guard let full = frame.bitmap else { return }
        let bitmap = full.cropped(to: column)
        let current = (bitmap: bitmap, fingerprint: bitmap.fingerprint, backgrounds: bitmap.stripBackgrounds)
        lock.lock()
        defer { lock.unlock() }
        defer { previous = current }
        guard let previous, previous.fingerprint.strips.count == current.fingerprint.strips.count else { return }

        // 找出底色或位图有变化的条，合并成连续的区间
        let differing = zip(previous.fingerprint.strips, current.fingerprint.strips).map { ($0 ^ $1).nonzeroBitCount }
        let changed = differing.indices.filter {
            differing[$0] > 0 || abs(previous.backgrounds[$0] - current.backgrounds[$0]) > 3
        }
        guard !changed.isEmpty, printed < 80 else { return }
        printed += 1
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            if let last = ranges.last, index == last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...index
            } else {
                ranges.append(index...index)
            }
        }
        let isChange = current.fingerprint.differs(from: previous.fingerprint)
        let details = ranges.prefix(6).map { range -> String in
            let most = range.map { differing[$0] }.max() ?? 0
            // 区间的第一条通常落在行顶部的留白里，那里的中位数就是真正的底色
            return String(
                format: "条%d–%d 底色%.0f→%.0f 最多%d格", range.lowerBound, range.upperBound,
                previous.backgrounds[range.lowerBound], current.backgrounds[range.lowerBound], most)
        }
        report.line(String(format: "  t=%5.1fs 判为变化=%@  %@%@", frame.time, isChange ? "是" : "否",
                           details.joined(separator: "；"), ranges.count > 6 ? " …共\(ranges.count)段" : ""))
    }
}

/// 文字框的统计：位置、字数和末尾的标点，不输出文字本身。
func describeText(in image: CGImage, scale: CGFloat, columnWidth: CGFloat) throws {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    let start = Date()
    try VNImageRequestHandler(cgImage: image).perform([request])
    let width = CGFloat(image.width) / scale, height = CGFloat(image.height) / scale

    /// 末尾连续的非文字、非数字字符（标点和符号），最多 6 个。
    func tail(_ text: String) -> String {
        String(text.reversed().prefix { !$0.isLetter && !$0.isNumber }.prefix(6).reversed())
            .unicodeScalars.map { String(format: "%@(U+%04X)", String($0), $0.value) }.joined()
    }
    var boxes: [TextBox] = []
    report.line("  识别耗时 \(Int(Date().timeIntervalSince(start) * 1000)) ms；图片 \(image.width)×\(image.height) px，缩放 \(scale)")
    for observation in (request.results ?? []).sorted(by: { $0.boundingBox.maxY > $1.boundingBox.maxY }) {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let box = observation.boundingBox
        let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        boxes.append(TextBox(text: candidate.string, rect: rect))
        report.line(String(
            format: "  框 x=%6.1f y=%6.1f w=%6.1f h=%5.1f 置信度=%.2f 字数=%2d 末尾=%@",
            rect.minX, rect.minY, rect.width, rect.height, candidate.confidence, candidate.string.count,
            tail(candidate.string).isEmpty ? "无" : tail(candidate.string)))
    }
    let rows = ListRowParser.parse(boxes, columnWidth: columnWidth)
    report.line("  行切分：\(rows.count) 行")
    for row in rows {
        report.line(String(
            format: "  行 带区 y=%6.1f–%6.1f 名称字数=%2d 末尾=%@", row.band.minY, row.band.maxY, row.name.count,
            tail(row.name).isEmpty ? "无" : tail(row.name)))
    }
}

// MARK: - 自检

/// 不截图，只检查本脚本的比较逻辑是否可靠。
func selfCheck() {
    var window = Bitmap(width: 600, height: 400, bytesPerRow: 2400, pixels: [UInt8](repeating: 255, count: 600 * 400 * 4))
    for y in 0..<400 {
        for x in 0..<600 {
            let offset = (y * 600 + x) * 4
            window.pixels[offset] = UInt8((x * 7 + y * 3) % 256)
            window.pixels[offset + 1] = UInt8((x * 2 + y * 5) % 256)
            window.pixels[offset + 2] = UInt8((x + y * 11) % 256)
        }
    }
    let column = CGRect(x: 60, y: 0, width: 242, height: 344)
    let crop = window.cropped(to: column)
    precondition(crop.width == 242 && crop.height == 344, "裁剪尺寸不对")
    precondition(crop.meanDifference(from: window.cropped(to: column)) == 0, "同一块区域应当没有差别")
    let squeezed = window.scaledToFit(width: 242, height: 344)
    precondition(squeezed.width == 242 && squeezed.height == 161, "缩小后的尺寸不对")
    precondition((crop.meanDifference(from: squeezed) ?? 0) > 20, "裁剪和缩小的整窗应当差别明显")
    precondition(window.hasOpaqueBorder, "全不透明的画面应当判为边缘不透明")
    precondition(crop.fingerprint.strips.count == 43 && crop.stripBackgrounds.count == 43, "条数不对")
    print("自检通过")
}

// MARK: - 主流程

@main
enum CaptureProbe {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.contains("--self-check") {
            selfCheck()
            return
        }
        do {
            try await run()
        } catch {
            report.line("出错：\((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
        }
        report.save()
        print("\n报告已写到 \(Report.path)")
    }

    /// 精准遮挡的列表栏布局：读 QuietChat 的配置，没有就用默认值。只读布局的三个数字。
    static func columnLayout() -> (left: CGFloat, top: CGFloat, width: CGFloat, source: String) {
        let url = URL.applicationSupportDirectory.appending(components: "QuietChat", "config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (64, 0, 280, "默认值")
        }
        func number(_ dictionary: [String: Any]?, _ key: String) -> CGFloat? {
            (dictionary?[key] as? NSNumber).map { CGFloat(truncating: $0) }
        }
        if let precise = config["preciseListColumn"] as? [String: Any],
           let left = number(precise, "leftInset"), let top = number(precise, "topInset"), let width = number(precise, "width") {
            return (left, top, width, "配置中的 preciseListColumn")
        }
        let full = config["listColumn"] as? [String: Any]
        return (number(full, "leftInset") ?? 64, 0, number(full, "width") ?? 280, "由配置中的 listColumn 推导，上边距取 0")
    }

    static func run() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        report.line("QuietChat 截图探测报告  \(Date().formatted(date: .numeric, time: .shortened))  macOS \(version)")
        guard CGPreflightScreenCaptureAccess() else {
            report.line("这个终端没有屏幕录制权限。已发起申请：请在「系统设置 → 隐私与安全性」里允许当前终端录屏，退出并重新打开终端后再运行。")
            _ = CGRequestScreenCaptureAccess()
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.tencent.xinWeChat" && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= 400 && $0.frame.height >= 300
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let wechat = window.owningApplication else {
            report.line("没有找到显示在当前桌面上的微信主窗口。请打开微信主窗口后再运行。")
            return
        }
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) })
        else {
            report.line("找不到微信窗口所在的显示器。")
            return
        }

        let layout = columnLayout()
        let frame = window.frame
        // 列表栏（窗口坐标），不含底部 56 pt 的遮挡条
        let column = CGRect(x: layout.left, y: layout.top, width: layout.width, height: frame.height - layout.top - 56)
            .intersection(CGRect(origin: .zero, size: frame.size))
        report.line("微信主窗口：\(format(frame))，候选窗口 \(candidates.count) 个；显示器 \(format(display.frame))")
        report.line("列表栏（窗口坐标）：\(format(column))，来源：\(layout.source)")
        guard !column.isEmpty else {
            report.line("列表栏和窗口没有交集，无法继续。")
            return
        }
        print("开始之前：请解锁或退出 QuietChat，让微信的聊天列表露出来；探测过程中不要移动微信窗口。")

        // [A] 单窗口，整窗
        report.line("\n[A] 单窗口流，整窗，1 倍分辨率")
        let windowFilter = SCContentFilter(desktopIndependentWindow: window)
        report.line("  过滤器 contentRect=\(format(windowFilter.contentRect)) pointPixelScale=\(windowFilter.pointPixelScale)")
        let collectorA = try await withStream(
            filter: windowFilter, configuration: makeConfiguration(width: frame.width, height: frame.height)
        ) { _ in
            await sleep(seconds: 3)
            askAboutBadge("A")
            _ = report.ask("  [A] 菜单栏有没有出现录屏指示（紫色图标）？(y/n)")
        }
        guard let reference = describe(collectorA, expected: frame.size) else {
            report.line("整窗画面都拿不到，后面的比较无法进行。")
            return
        }

        // [B] 单窗口 + sourceRect
        report.line("\n[B] 单窗口流 + sourceRect（窗口坐标的列表栏）")
        let collectorB = try await withStream(
            filter: windowFilter,
            configuration: makeConfiguration(width: column.width, height: column.height, sourceRect: column)
        ) { _ in
            await sleep(seconds: 3)
        }
        compareCrop(describe(collectorB, expected: column.size), reference: reference, column: column)

        // [C] 按显示器截图 + sourceRect（显示器坐标）
        let displayColumn = column.offsetBy(dx: frame.minX - display.frame.minX, dy: frame.minY - display.frame.minY)
        let displayFilters: [(String, SCContentFilter)] = [
            ("C1 按显示器，只包含微信主窗口", SCContentFilter(display: display, including: [window])),
            ("C2 按显示器，只包含微信这个应用", SCContentFilter(display: display, including: [wechat], exceptingWindows: [])),
            ("C3 按显示器，排除微信以外的所有应用", SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter { $0.processID != wechat.processID },
                exceptingWindows: [])),
        ]
        var workingDisplayFilter: SCContentFilter?
        for (label, filter) in displayFilters {
            report.line("\n[\(label)] + sourceRect=\(format(displayColumn))")
            do {
                let collector = try await withStream(
                    filter: filter,
                    configuration: makeConfiguration(width: column.width, height: column.height, sourceRect: displayColumn)
                ) { _ in
                    await sleep(seconds: 3)
                    askAboutBadge(String(label.prefix(2)))
                }
                let bitmap = describe(collector, expected: column.size)
                compareCrop(bitmap, reference: reference, column: column)
                if let bitmap, let difference = bitmap.meanDifference(from: reference.cropped(to: column)), difference < 3 {
                    workingDisplayFilter = filter
                }
            } catch {
                report.line("  失败：\((error as NSError).domain) \((error as NSError).code)")
            }
        }

        // [D] 静帧
        report.line("\n[D] 静帧（SCScreenshotManager），每种取 5 张")
        let scale = CGFloat(windowFilter.pointPixelScale)
        var still: CGImage?
        for _ in 0..<5 {
            still = try await SCScreenshotManager.captureImage(
                contentFilter: windowFilter,
                configuration: makeConfiguration(width: frame.width * scale, height: frame.height * scale))
            await sleep(seconds: 0.4)
        }
        report.line("  单窗口整窗：\(still.map { "\($0.width)×\($0.height) px" } ?? "失败")（期望 \(Int(frame.width * scale))×\(Int(frame.height * scale))）")
        _ = report.ask("  [D 单窗口] 刚才取静帧时，微信的标题栏有没有闪过紫色图标？(y/n)")
        if let workingDisplayFilter {
            var cropped: CGImage?
            for _ in 0..<5 {
                cropped = try await SCScreenshotManager.captureImage(
                    contentFilter: workingDisplayFilter,
                    configuration: makeConfiguration(
                        width: column.width * scale, height: column.height * scale, sourceRect: displayColumn))
                await sleep(seconds: 0.4)
            }
            report.line("  按显示器 + sourceRect：\(cropped.map { "\($0.width)×\($0.height) px" } ?? "失败")（期望 \(Int(column.width * scale))×\(Int(column.height * scale))）")
            _ = report.ask("  [D 按显示器] 刚才取静帧时，微信的标题栏有没有闪过紫色图标？(y/n)")
        } else {
            report.line("  没有可用的按显示器过滤器，跳过。")
        }

        // [E] 悬停、点击、滚动
        report.line("\n[E] 悬停、点击、滚动时指纹的变化（整窗流，取列表栏部分）")
        print("  接下来请依次操作，每步之间停 2～3 秒：")
        print("    1. 把鼠标移到列表的某一行上，停住；")
        print("    2. 点击这一行；")
        print("    3. 点击另一行；")
        print("    4. 滚动一下列表。")
        let logger = ChangeLogger(column: column)
        _ = try await withStream(
            filter: windowFilter, configuration: makeConfiguration(width: frame.width, height: frame.height),
            onBitmap: { logger.handle($0) }
        ) { _ in
            _ = report.ask("  做完后按回车。")
        }

        // [F] 文字框
        report.line("\n[F] 列表栏的文字框（只有位置、字数和末尾的标点，没有文字内容）")
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: windowFilter, configuration: makeConfiguration(width: frame.width * scale, height: frame.height * scale))
        let imageScale = CGFloat(image.width) / frame.width
        if let columnImage = image.cropping(to: CGRect(
            x: column.minX * imageScale, y: column.minY * imageScale,
            width: column.width * imageScale, height: column.height * imageScale)) {
            try describeText(in: columnImage, scale: imageScale, columnWidth: column.width)
        } else {
            report.line("  裁不出列表栏。")
        }
    }
}
