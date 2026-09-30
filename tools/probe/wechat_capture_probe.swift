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
//   /tmp/quietchat-capture-probe            第一轮：比较各种取图方式（流、按显示器、静帧）
//   /tmp/quietchat-capture-probe --stills   第二轮：定时取静帧（应用采用的方式）：有没有共享标记、开销、悬停与点击、文字框
// 运行前请解锁或退出 QuietChat，让微信的聊天列表露出来；过程中按提示观察和操作。
// 报告同时写到 /tmp/quietchat-capture-probe.txt（第二轮为 /tmp/quietchat-capture-probe-stills.txt）。
// 加 --self-check 只检查脚本自身的计算，不截图。

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Vision

// MARK: - 报告

final class Report: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var lines: [String] = []

    init(path: String) {
        self.path = path
    }

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
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

let stillsMode = CommandLine.arguments.contains("--stills")
let report = Report(path: stillsMode ? "/tmp/quietchat-capture-probe-stills.txt" : "/tmp/quietchat-capture-probe.txt")

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

    var fingerprint: ContentFingerprint { fingerprint(scale: 1) }

    /// 与应用里的算法一致：原生分辨率的图直接按每 pt 的像素数计算，不先缩小。
    func fingerprint(scale: Int) -> ContentFingerprint {
        pixels.withUnsafeBytes {
            ContentFingerprint(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow, scale: scale)
        }
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

extension Bitmap {
    /// 读出像素缓冲区的内容（BGRA）。
    init?(pixelBuffer buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let height = CVPixelBufferGetHeight(buffer), bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        self.init(
            width: CVPixelBufferGetWidth(buffer), height: height, bytesPerRow: bytesPerRow,
            pixels: [UInt8](UnsafeRawBufferPointer(start: base, count: height * bytesPerRow)))
    }

    /// 把图片画成 BGRA 位图。
    init?(image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
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
            frame.bitmap = Bitmap(pixelBuffer: buffer)
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
        guard let previous, let differing = current.fingerprint.differingCellCounts(from: previous.fingerprint) else { return }

        // 找出底色或指纹有变化的条，合并成连续的区间
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

// MARK: - 定时取静帧

/// 窗口服务器报告的窗口外框（Quartz 全局坐标）；QuietChat 的遮罩用的就是这个位置。
func windowServerBounds(of windowID: CGWindowID) -> CGRect? {
    let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]) ?? []
    guard let entry = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
          let bounds = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
}

/// 本进程累计使用的 CPU 时间（秒）。
func ownCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

/// 把 ps 输出的累计 CPU 时间（形如 "53:02.69"，分:秒，超过一小时为 时:分:秒）换算成秒。
func parseCPUTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
}

/// 指定名称的系统进程累计使用的 CPU 时间（秒），通过 ps 读取；读不到时返回 nil。
func cpuSeconds(ofProcessNamed name: String) -> Double? {
    func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    guard let pid = output("/usr/bin/pgrep", ["-x", name])?.split(separator: "\n").first,
          let text = output("/bin/ps", ["-o", "cputime=", "-p", String(pid)]) else { return nil }
    return parseCPUTime(text)
}

/// 一段时间里本进程、replayd（系统的截图服务）和 WindowServer 各用了多少 CPU。
struct CPUMeter {
    private let start = Date()
    private let own = ownCPUSeconds()
    private let replayd = cpuSeconds(ofProcessNamed: "replayd")
    private let windowServer = cpuSeconds(ofProcessNamed: "WindowServer")

    /// 以单核的百分比表示；读不到的进程显示"未知"。
    func summary() -> String {
        let elapsed = Date().timeIntervalSince(start)
        func percent(_ before: Double?, _ after: Double?) -> String {
            guard let before, let after, elapsed > 0 else { return "未知" }
            return String(format: "%.1f%%", (after - before) / elapsed * 100)
        }
        return String(format: "%.1f 秒内 CPU：本进程 ", elapsed) + percent(own, ownCPUSeconds())
            + "，replayd " + percent(replayd, cpuSeconds(ofProcessNamed: "replayd"))
            + "，WindowServer " + percent(windowServer, cpuSeconds(ofProcessNamed: "WindowServer"))
    }
}

struct ProbeError: Error {}

/// 取一张静帧（像素缓冲区）；返回画面、耗时（毫秒）和随图附带的几何信息。
func captureStill(
    filter: SCContentFilter, configuration: SCStreamConfiguration
) async throws -> (bitmap: Bitmap, milliseconds: Double, info: String) {
    let start = Date()
    let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
    let milliseconds = Date().timeIntervalSince(start) * 1000
    guard let buffer = sampleBuffer.imageBuffer, let bitmap = Bitmap(pixelBuffer: buffer) else { throw ProbeError() }
    let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
    func rect(_ key: SCStreamFrameInfo) -> CGRect? {
        (attachments[key] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }
    func number(_ key: SCStreamFrameInfo) -> String {
        (attachments[key] as? NSNumber).map { String(format: "%.3f", $0.doubleValue) } ?? "无"
    }
    let info = "contentRect=\(format(rect(.contentRect))) contentScale=\(number(.contentScale)) scaleFactor=\(number(.scaleFactor))"
    return (bitmap, milliseconds, info)
}

/// 两帧指纹相比，不同格数最多的那一条有几格不同；条数不同时返回 nil。
func maxDifferingCells(_ lhs: ContentFingerprint, _ rhs: ContentFingerprint) -> Int? {
    lhs.differingCellCounts(from: rhs).map { $0.max() ?? 0 }
}

func statistics(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "无数据" }
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(values.count)
    return String(
        format: "平均 %.1f，中位 %.1f，95%% %.1f，最大 %.1f",
        mean, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted[sorted.count - 1])
}

/// 每隔 interval 秒取一张图，持续 seconds 秒；统计耗时，以及画面静止时相邻两张图的指纹差了多少。
func poll(
    seconds: Double, interval: Double = 0.1, scale: Int = 1,
    capture: () async throws -> (bitmap: Bitmap, milliseconds: Double)
) async {
    var latencies: [Double] = [], processing: [Double] = [], differing: [Int] = []
    var failures = 0, flagged = 0
    var previous: ContentFingerprint?
    let meter = CPUMeter()
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        let tick = Date()
        do {
            let still = try await capture()
            // capture 返回的耗时只算取图；算指纹另计
            let processingStart = Date()
            let fingerprint = still.bitmap.fingerprint(scale: scale)
            processing.append(Date().timeIntervalSince(processingStart) * 1000)
            latencies.append(still.milliseconds)
            if let previous {
                if fingerprint.differs(from: previous) { flagged += 1 }
                differing.append(maxDifferingCells(fingerprint, previous) ?? -1)
            }
            previous = fingerprint
        } catch {
            failures += 1
        }
        let remaining = interval - Date().timeIntervalSince(tick)
        if remaining > 0 { await sleep(seconds: remaining) }
    }
    let elapsed = Date().timeIntervalSince(start)
    report.line(String(format: "  取图 %d 次（%.1f 次/秒），失败 %d 次", latencies.count, Double(latencies.count) / elapsed, failures))
    report.line("  每次取图耗时（ms）：\(statistics(latencies))")
    report.line("  每次算指纹耗时（ms）：\(statistics(processing))")
    report.line("  相邻两张图：判为变化 \(flagged) 次；不同格数最多的一条：\(differing.max().map(String.init) ?? "无数据") 格"
        + "（各次：\(Dictionary(grouping: differing, by: { $0 }).sorted { $0.key < $1.key }.map { "\($0.key)格×\($0.value.count)" }.joined(separator: " "))）")
    report.line("  \(meter.summary())")
}

/// 定时取图时记录悬停、点击、滚动造成的变化；同时比较"取 1 倍图"和"取 2 倍图"两种做法（应用里用的是后者）。
final class PollLogger {
    private struct State {
        var fingerprint: ContentFingerprint
        var backgrounds: [Double]
        init(_ bitmap: Bitmap, scale: Int = 1) {
            fingerprint = bitmap.fingerprint(scale: scale)
            // 底色只从 1 倍图里读
            backgrounds = scale == 1 ? bitmap.stripBackgrounds : []
        }
    }

    private var previousSmall: State?
    private var previousLarge: State?
    private var printed = 0

    func handle(time: Double, small: Bitmap, large: Bitmap?) {
        let currentSmall = State(small), currentLarge = large.map { State($0, scale: 2) }
        defer {
            previousSmall = currentSmall
            previousLarge = currentLarge
        }
        guard let previousSmall,
              let differing = currentSmall.fingerprint.differingCellCounts(from: previousSmall.fingerprint) else { return }
        let changed = differing.indices.filter {
            differing[$0] > 0 || abs(previousSmall.backgrounds[$0] - currentSmall.backgrounds[$0]) > 3
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
        func verdict(_ previous: State?, _ current: State?) -> String {
            guard let previous, let current, let most = maxDifferingCells(previous.fingerprint, current.fingerprint) else { return "无" }
            return "变化=\(current.fingerprint.differs(from: previous.fingerprint) ? "是" : "否") 最多\(most)格"
        }
        let details = ranges.prefix(4).map { range in
            String(format: "条%d–%d 底色%.0f→%.0f", range.lowerBound, range.upperBound,
                   previousSmall.backgrounds[range.lowerBound], currentSmall.backgrounds[range.lowerBound])
        }
        report.line(String(format: "  t=%5.1fs 1倍[%@] 2倍[%@]  %@%@", time,
                           verdict(previousSmall, currentSmall), verdict(previousLarge, currentLarge),
                           details.joined(separator: "；"), ranges.count > 4 ? " …共\(ranges.count)段" : ""))
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
    precondition(window.fingerprint(scale: 2).strips.count == 25, "按 2 倍计算时每条应当是 16 像素高")
    precondition(parseCPUTime("53:02.69") == 3182.69 && parseCPUTime(" 1:02:03.5\n") == 3723.5, "CPU 时间换算不对")
    precondition(parseCPUTime("") == nil, "空字符串不应该换算出时间")
    precondition(maxDifferingCells(crop.fingerprint, crop.fingerprint) == 0, "同一帧的指纹应当没有差别")
    print("自检通过")
}

// MARK: - 主流程

@main
enum CaptureProbe {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.contains("--self-check") {
            selfCheck()
            return
        }
        // 命令行程序不会自动建立与窗口服务器的连接，创建单窗口过滤器时 CoreGraphics 会断言失败（CGS_REQUIRE_INIT）。
        // 查询一次显示器并初始化 AppKit 就能建立连接；不显示 Dock 图标，也不激活。
        _ = CGMainDisplayID()
        NSApplication.shared.setActivationPolicy(.prohibited)
        _ = NSScreen.screens

        if stillsMode {
            await runStills()
        } else {
            await run()
        }
        report.save()
        print("\n报告已写到 \(report.path)")
    }

    /// 执行一步：出错只记录，不影响后面的步骤；每步结束都保存报告，中途崩溃也能留下已有的结果。
    @MainActor
    static func step(_ title: String, _ body: @MainActor () async throws -> Void) async {
        report.line("\n\(title)")
        do {
            try await body()
        } catch {
            report.line("  失败：\((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
        }
        report.save()
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

    struct Target {
        var content: SCShareableContent
        var window: SCWindow
        var wechat: SCRunningApplication
        var display: SCDisplay
        /// 窗口外框（Quartz 全局坐标），以窗口服务器为准。
        var frame: CGRect
        /// 列表栏（窗口坐标），不含底部 56 pt 的遮挡条。
        var column: CGRect
    }

    /// 检查权限、找到微信主窗口并算出列表栏；找不到时已把原因写进报告，返回 nil。
    @MainActor
    static func locate(title: String) async -> Target? {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        report.line("\(title)  \(Date().formatted(date: .numeric, time: .shortened))  macOS \(version)")
        guard CGPreflightScreenCaptureAccess() else {
            report.line("这个终端没有屏幕录制权限。已发起申请：请在「系统设置 → 隐私与安全性」里允许当前终端录屏，退出并重新打开终端后再运行。")
            _ = CGRequestScreenCaptureAccess()
            return nil
        }

        let content: SCShareableContent
        let queryStart = Date()
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            report.line("读取可截图的内容失败：\((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
            return nil
        }
        let queryMilliseconds = Int(Date().timeIntervalSince(queryStart) * 1000)
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.tencent.xinWeChat" && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= 400 && $0.frame.height >= 300
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let wechat = window.owningApplication else {
            report.line("没有找到显示在当前桌面上的微信主窗口。请打开微信主窗口后再运行。")
            return nil
        }
        // ScreenCaptureKit 报告的窗口位置在第一轮探测里和实际对不上，几何一律以窗口服务器为准
        let serverFrame = windowServerBounds(of: window.windowID)
        let frame = serverFrame ?? window.frame
        report.line("微信主窗口：窗口服务器 \(format(serverFrame))，ScreenCaptureKit \(format(window.frame))；"
            + "候选窗口 \(candidates.count) 个；查询可截图内容耗时 \(queryMilliseconds) ms")
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else {
            report.line("找不到微信窗口所在的显示器。")
            return nil
        }

        let layout = columnLayout()
        let column = CGRect(x: layout.left, y: layout.top, width: layout.width, height: frame.height - layout.top - 56)
            .intersection(CGRect(origin: .zero, size: frame.size))
        report.line("显示器 \(format(display.frame))；列表栏（窗口坐标）：\(format(column))，来源：\(layout.source)")
        guard !column.isEmpty else {
            report.line("列表栏和窗口没有交集，无法继续。")
            return nil
        }
        print("开始之前：请解锁或退出 QuietChat，让微信的聊天列表露出来；探测过程中不要移动微信窗口。")
        return Target(content: content, window: window, wechat: wechat, display: display, frame: frame, column: column)
    }

    @MainActor
    static func run() async {
        guard let target = await locate(title: "QuietChat 截图探测报告") else { return }
        let (content, window, wechat, display) = (target.content, target.window, target.wechat, target.display)
        let (frame, column) = (target.frame, target.column)

        let windowFilter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(windowFilter.pointPixelScale)
        report.line("单窗口过滤器：contentRect=\(format(windowFilter.contentRect)) pointPixelScale=\(windowFilter.pointPixelScale)")
        report.save()

        // 整窗画面，后面各种取图方式都和它比较
        var reference: Bitmap?
        await step("[A] 单窗口流，整窗，1 倍分辨率") {
            let collector = try await withStream(
                filter: windowFilter, configuration: makeConfiguration(width: frame.width, height: frame.height)
            ) { _ in
                await sleep(seconds: 3)
                askAboutBadge("A")
                _ = report.ask("  [A] 菜单栏有没有出现录屏指示（紫色图标）？(y/n)")
            }
            reference = describe(collector, expected: frame.size)
        }

        await step("[B] 单窗口流 + sourceRect（窗口坐标的列表栏）") {
            let collector = try await withStream(
                filter: windowFilter,
                configuration: makeConfiguration(width: column.width, height: column.height, sourceRect: column)
            ) { _ in
                await sleep(seconds: 3)
            }
            let bitmap = describe(collector, expected: column.size)
            if let reference { compareCrop(bitmap, reference: reference, column: column) }
        }

        // 按显示器截图时，sourceRect 用显示器坐标
        let displayColumn = column.offsetBy(dx: frame.minX - display.frame.minX, dy: frame.minY - display.frame.minY)
        let displayFilters: [(String, SCContentFilter)] = [
            ("C1 按显示器，只包含微信主窗口", SCContentFilter(display: display, including: [window])),
            ("C2 按显示器，只包含微信这个应用", SCContentFilter(display: display, including: [wechat], exceptingWindows: [])),
            ("C3 按显示器，排除微信以外的所有应用", SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter { $0.processID != wechat.processID },
                exceptingWindows: [])),
        ]
        var workingDisplayFilter: (label: String, filter: SCContentFilter)?
        for (label, filter) in displayFilters {
            await step("[\(label)] + sourceRect=\(format(displayColumn))") {
                let collector = try await withStream(
                    filter: filter,
                    configuration: makeConfiguration(width: column.width, height: column.height, sourceRect: displayColumn)
                ) { _ in
                    await sleep(seconds: 3)
                    askAboutBadge(String(label.prefix(2)))
                }
                let bitmap = describe(collector, expected: column.size)
                guard let reference else { return }
                compareCrop(bitmap, reference: reference, column: column)
                if let bitmap, let difference = bitmap.meanDifference(from: reference.cropped(to: column)), difference < 3 {
                    workingDisplayFilter = (label, filter)
                }
            }
        }

        await step("[D] 静帧（SCScreenshotManager），每种取 5 张") {
            var still: CGImage?
            for _ in 0..<5 {
                still = try await SCScreenshotManager.captureImage(
                    contentFilter: windowFilter,
                    configuration: makeConfiguration(width: frame.width * scale, height: frame.height * scale))
                await sleep(seconds: 0.4)
            }
            report.line("  单窗口整窗：\(still.map { "\($0.width)×\($0.height) px" } ?? "失败")（期望 \(Int(frame.width * scale))×\(Int(frame.height * scale))）")
            _ = report.ask("  [D 单窗口] 刚才取静帧时，微信的标题栏有没有闪过紫色图标？(y/n)")

            guard let workingDisplayFilter else {
                report.line("  没有裁剪生效的按显示器过滤器，跳过。")
                return
            }
            var cropped: CGImage?
            for _ in 0..<5 {
                cropped = try await SCScreenshotManager.captureImage(
                    contentFilter: workingDisplayFilter.filter,
                    configuration: makeConfiguration(
                        width: column.width * scale, height: column.height * scale, sourceRect: displayColumn))
                await sleep(seconds: 0.4)
            }
            report.line("  \(workingDisplayFilter.label) + sourceRect：\(cropped.map { "\($0.width)×\($0.height) px" } ?? "失败")（期望 \(Int(column.width * scale))×\(Int(column.height * scale))）")
            _ = report.ask("  [D 按显示器] 刚才取静帧时，微信的标题栏有没有闪过紫色图标？(y/n)")
        }

        await step("[E] 悬停、点击、滚动时指纹的变化（整窗流，取列表栏部分）") {
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
        }

        await step("[F] 列表栏的文字框（只有位置、字数和末尾的标点，没有文字内容）") {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: windowFilter,
                configuration: makeConfiguration(width: frame.width * scale, height: frame.height * scale))
            let imageScale = CGFloat(image.width) / frame.width
            guard let columnImage = image.cropping(to: CGRect(
                x: column.minX * imageScale, y: column.minY * imageScale,
                width: column.width * imageScale, height: column.height * imageScale)) else {
                report.line("  裁不出列表栏。")
                return
            }
            try describeText(in: columnImage, scale: imageScale, columnWidth: column.width)
        }
    }
    /// 第二轮：不开持续的流，定时取静帧。
    @MainActor
    static func runStills() async {
        guard let target = await locate(title: "QuietChat 定时取静帧探测报告") else { return }
        let (frame, column) = (target.frame, target.column)
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let scale = CGFloat(filter.pointPixelScale)
        report.line("单窗口过滤器：contentRect=\(format(filter.contentRect)) pointPixelScale=\(filter.pointPixelScale)")
        report.save()

        // 裁到列表栏：sourceRect 用窗口坐标；输出尺寸取 1 倍或显示器的原生倍数
        let smallConfiguration = { makeConfiguration(width: column.width, height: column.height, sourceRect: column) }
        let largeConfiguration = {
            makeConfiguration(width: column.width * scale, height: column.height * scale, sourceRect: column)
        }
        let scaledColumn = CGRect(
            x: column.minX * scale, y: column.minY * scale, width: column.width * scale, height: column.height * scale)

        await step("[G] 静帧 + sourceRect 是否生效") {
            let full = try await captureStill(
                filter: filter, configuration: makeConfiguration(width: frame.width, height: frame.height))
            let crop = try await captureStill(filter: filter, configuration: smallConfiguration())
            report.line("  1 倍整窗 \(full.bitmap.width)×\(full.bitmap.height)，\(full.info)")
            report.line("  1 倍列表栏 \(crop.bitmap.width)×\(crop.bitmap.height)（期望 \(Int(column.width))×\(Int(column.height))），\(crop.info)")
            compareCrop(crop.bitmap, reference: full.bitmap, column: column)

            guard scale == 2 else {
                report.line("  显示器不是 2 倍分辨率，不再测原生分辨率。")
                return
            }
            let fullLarge = try await captureStill(
                filter: filter, configuration: makeConfiguration(width: frame.width * scale, height: frame.height * scale))
            let cropLarge = try await captureStill(filter: filter, configuration: largeConfiguration())
            report.line("  2 倍整窗 \(fullLarge.bitmap.width)×\(fullLarge.bitmap.height)，\(fullLarge.info)")
            report.line("  2 倍列表栏 \(cropLarge.bitmap.width)×\(cropLarge.bitmap.height)（期望 \(Int(scaledColumn.width))×\(Int(scaledColumn.height))），\(cropLarge.info)")
            compareCrop(cropLarge.bitmap, reference: fullLarge.bitmap, column: scaledColumn)

            // 两种取法的指纹是否一致（应用里只用 2 倍图，不混用）
            let large = cropLarge.bitmap.fingerprint(scale: 2)
            report.line("  2 倍图与 1 倍图的指纹：判为变化=\(large.differs(from: crop.bitmap.fingerprint) ? "是" : "否")，"
                + "不同格数最多的一条 \(maxDifferingCells(large, crop.bitmap.fingerprint).map(String.init) ?? "条数不同") 格")

            // 识别用的是图片接口，确认它同样按 sourceRect 裁剪
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: largeConfiguration())
            let difference = Bitmap(image: image).flatMap { $0.meanDifference(from: cropLarge.bitmap) }
            report.line("  图片接口 \(image.width)×\(image.height) px；与像素缓冲区接口的平均差 = "
                + (difference.map { String(format: "%.2f", $0) } ?? "无法比较"))
        }

        await step("[H0] 不取图时的 CPU 基线（5 秒）") {
            let meter = CPUMeter()
            await sleep(seconds: 5)
            report.line("  \(meter.summary())")
        }

        let watchHint = "  接下来 10 秒请盯着微信窗口左上角的红绿灯和菜单栏右侧，看有没有紫色图标出现或闪烁。先不要操作微信。"
        await step("[H1] 每 0.1 秒取一张 1 倍图，持续 10 秒") {
            print(watchHint)
            await sleep(seconds: 2)
            await poll(seconds: 10) {
                let still = try await captureStill(filter: filter, configuration: smallConfiguration())
                return (still.bitmap, still.milliseconds)
            }
            _ = report.ask("  [H1] 这 10 秒里微信红绿灯处的紫色图标：1 没有  2 一直有  3 闪烁？")
            _ = report.ask("  [H1] 这 10 秒里菜单栏的录屏指示：1 没有  2 一直有  3 闪烁？")
        }

        if scale == 2 {
            await step("[H2] 每 0.1 秒取一张 2 倍图，持续 10 秒") {
                print(watchHint)
                await sleep(seconds: 2)
                await poll(seconds: 10, scale: 2) {
                    let still = try await captureStill(filter: filter, configuration: largeConfiguration())
                    return (still.bitmap, still.milliseconds)
                }
                _ = report.ask("  [H2] 这 10 秒里微信红绿灯处的紫色图标：1 没有  2 一直有  3 闪烁？")
                _ = report.ask("  [H2] 这 10 秒里菜单栏的录屏指示：1 没有  2 一直有  3 闪烁？")
            }
        }

        await step("[I] 定时取图时的悬停、点击、滚动") {
            print("  接下来请依次操作，每步之间停 2～3 秒：")
            print("    1. 把鼠标移到列表的某一行上，停住；")
            print("    2. 点击这一行；")
            print("    3. 点击另一行；")
            print("    4. 滚动一下列表。")
            let logger = PollLogger()
            let polling = Task.detached {
                let start = Date()
                while !Task.isCancelled {
                    let tick = Date()
                    if let small = try? await captureStill(filter: filter, configuration: smallConfiguration()) {
                        let large = scale == 2
                            ? try? await captureStill(filter: filter, configuration: largeConfiguration()) : nil
                        logger.handle(time: Date().timeIntervalSince(start), small: small.bitmap, large: large?.bitmap)
                    }
                    let remaining = 0.1 - Date().timeIntervalSince(tick)
                    if remaining > 0 { await sleep(seconds: remaining) }
                }
            }
            _ = report.ask("  做完后按回车。")
            polling.cancel()
            await polling.value
        }

        await step("[J] 列表栏的文字框（只有位置、字数和末尾的标点，没有文字内容）") {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: largeConfiguration())
            try describeText(in: image, scale: CGFloat(image.width) / column.width, columnWidth: column.width)
        }
    }
}
