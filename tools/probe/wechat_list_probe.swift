// 验证脚本：对微信聊天列表截图做 OCR 与背景色扫描，评估"截图识别"方案是否可行。
// 边界：只读取本地图片，不申请系统权限、不联网；结果打印到终端，并在图片旁生成 *.probe.png 标注图。
// 用法：swift wechat_list_probe.swift <截图路径> [白名单名称 ...]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct TextBox {
    let text: String
    let confidence: Float
    /// 像素坐标，原点在左上角
    let rect: CGRect
}

struct Segment {
    var start: Int
    var end: Int
    var r: Double
    var g: Double
    var b: Double
    var count: Double

    var length: Int { end - start + 1 }
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    var hex: String { String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded())) }
}

struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        data = buffer
    }

    /// 位图内存第 0 行对应图片顶部，因此 y 与左上原点坐标一致
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
    }
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        fputs("无法读取图片：\(path)\n", stderr)
        exit(1)
    }
    return image
}

func recognize(_ image: CGImage, customWords: [String]) throws -> [TextBox] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    request.customWords = customWords
    try VNImageRequestHandler(cgImage: image).perform([request])

    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    return (request.results ?? []).compactMap { observation in
        guard let top = observation.topCandidates(1).first else { return nil }
        let b = observation.boundingBox  // Vision 返回归一化坐标，原点在左下
        return TextBox(
            text: top.string, confidence: top.confidence,
            rect: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
    }
    .sorted { $0.rect.minY < $1.rect.minY }
}

/// 找出最多文字共享的左对齐 x（名称和消息预览都从这里开始）
func dominantLeftX(_ boxes: [TextBox], tolerance: CGFloat) -> CGFloat? {
    let best = boxes.max { a, b in
        boxes.filter { abs($0.rect.minX - a.rect.minX) <= tolerance }.count
            < boxes.filter { abs($0.rect.minX - b.rect.minX) <= tolerance }.count
    }
    guard let anchor = best else { return nil }
    return boxes.filter { abs($0.rect.minX - anchor.rect.minX) <= tolerance }.map(\.rect.minX).min()
}

/// 沿一列像素做颜色游程分段；短于 minLength 的段（分隔线、抗锯齿）被丢弃
func scanColumn(_ pixels: Pixels, x: Int, tolerance: Double = 6, minLength: Int = 8) -> [Segment] {
    var segments: [Segment] = []
    var current: Segment?
    for y in 0..<pixels.height {
        let (r, g, b) = pixels.rgb(x, y)
        if var c = current, abs(r - c.r) <= tolerance, abs(g - c.g) <= tolerance, abs(b - c.b) <= tolerance {
            c.count += 1
            c.r += (r - c.r) / c.count
            c.g += (g - c.g) / c.count
            c.b += (b - c.b) / c.count
            c.end = y
            current = c
        } else {
            if let c = current { segments.append(c) }
            current = Segment(start: y, end: y, r: r, g: g, b: b, count: 1)
        }
    }
    if let c = current { segments.append(c) }
    return segments.filter { $0.length >= minLength }
}

func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "…", with: "")
        .replacingOccurrences(of: "...", with: "")
        .trimmingCharacters(in: .whitespaces)
}

func matchesWhitelist(_ name: String, _ whitelist: [String]) -> String? {
    let n = normalize(name)
    guard !n.isEmpty else { return nil }
    return whitelist.first { w in n == w || w.hasPrefix(n) || n.hasPrefix(w) }
}

func writeAnnotation(
    _ image: CGImage, names: [TextBox], others: [TextBox], columnX: Int, to url: URL
) {
    let w = image.width
    let h = image.height
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // 翻转为左上原点，和 TextBox 坐标一致
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setLineWidth(2)
    ctx.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 1, alpha: 0.9))
    others.forEach { ctx.stroke($0.rect) }
    ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 1, blue: 0.3, alpha: 1))
    names.forEach { ctx.stroke($0.rect) }
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 0.9))
    ctx.move(to: CGPoint(x: columnX, y: 0))
    ctx.addLine(to: CGPoint(x: columnX, y: h))
    ctx.strokePath()

    guard let output = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, output, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：swift wechat_list_probe.swift <截图路径> [白名单名称 ...]")
    exit(1)
}
let imagePath = args[1]
let whitelist = Array(args.dropFirst(2))
let image = loadImage(imagePath)
let pixels = Pixels(image)
print("图片尺寸：\(image.width) × \(image.height) px\n")

let start = Date()
let boxes = try recognize(image, customWords: whitelist)
let elapsed = Int(Date().timeIntervalSince(start) * 1000)

print("== 1. OCR 原始结果（耗时 \(elapsed) ms）==")
for b in boxes {
    print(
        String(
            format: "  y=%4.0f x=%4.0f h=%3.0f  置信度 %.2f  %@", b.rect.minY, b.rect.minX, b.rect.height,
            b.confidence, b.text))
}

let tolerance = CGFloat(image.width) * 0.02
guard let leftX = dominantLeftX(boxes, tolerance: tolerance) else {
    print("\n未识别到文字，无法继续")
    exit(1)
}
let leftAligned = boxes.filter { abs($0.rect.minX - leftX) <= tolerance }
// 深色模式下名称是白字、预览是灰字：用框内最亮笔画的亮度一分为二（框高会被 g/y 等下伸字母干扰，不可靠）
func textBrightness(_ rect: CGRect) -> Double {
    var values: [Double] = []
    for y in stride(from: Int(rect.minY), to: min(Int(rect.maxY), pixels.height), by: 2) {
        for x in stride(from: Int(rect.minX), to: min(Int(rect.maxX), pixels.width), by: 2) {
            let (r, g, b) = pixels.rgb(x, y)
            values.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
    }
    values.sort()
    return values.isEmpty ? 0 : values[Int(Double(values.count - 1) * 0.98)]
}
let brightness = leftAligned.map { textBrightness($0.rect) }
let threshold = ((brightness.min() ?? 0) + (brightness.max() ?? 0)) / 2
let names = zip(leftAligned, brightness).filter { $0.1 >= threshold }.map(\.0)
let others = boxes.filter { box in !names.contains { $0.rect == box.rect } }

// 采样列取在头像与文字之间的空隙，这里应当只有背景色
let columnX = max(0, Int(leftX) - Int(CGFloat(image.width) * 0.015))
let segments = scanColumn(pixels, x: columnX)

print("\n== 2. 按行识别的名称（左对齐 x≈\(Int(leftX))，文字亮度阈值 \(Int(threshold))）==")
for n in names {
    let (r, g, b) = pixels.rgb(columnX, Int(n.rect.midY))
    let bg = Segment(start: 0, end: 0, r: r, g: g, b: b, count: 1)
    var line = String(format: "  y=%4.0f  背景 %@ (亮度 %5.1f)  %@", n.rect.midY, bg.hex, bg.luminance, n.text)
    if !whitelist.isEmpty {
        line += matchesWhitelist(n.text, whitelist).map { "  ✅ 命中白名单「\($0)」" } ?? "  ⬛️ 应遮挡"
    }
    print(line)
}

print("\n== 3. 背景色分段（采样列 x=\(columnX)，只列出 ≥8px 的段）==")
for s in segments {
    print(String(format: "  y=%4d–%4d  长 %4d px  %@  亮度 %5.1f", s.start, s.end, s.length, s.hex, s.luminance))
}

if !whitelist.isEmpty {
    let missing = whitelist.filter { w in !names.contains { matchesWhitelist($0.text, [w]) != nil } }
    print("\n== 4. 白名单中未在图里识别到的名称 ==")
    print(missing.isEmpty ? "  （无）" : missing.map { "  " + $0 }.joined(separator: "\n"))
}

let inputURL = URL(fileURLWithPath: imagePath)
let outputURL = inputURL.deletingPathExtension().appendingPathExtension("probe.png")
writeAnnotation(image, names: names, others: others, columnX: columnX, to: outputURL)
print("\n标注图：\(outputURL.path)")
print("  绿框 = 识别为名称，蓝框 = 其他文字，红线 = 背景色采样列")
