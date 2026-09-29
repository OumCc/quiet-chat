// 由 shared/brand/logo.svg 生成 macOS AppIcon 的全部 PNG 尺寸。
// logo.svg 是满版圆角方块；macOS 图标需要按系统网格在 1024 画布里留边（主体 824×824），这里统一缩放居中。
// 用法（仓库根目录）：swift tools/brand/make_macos_icons.swift

import AppKit

let source = URL(fileURLWithPath: "shared/brand/logo.svg")
let output = URL(fileURLWithPath: "macos/QuietChat/Assets.xcassets/AppIcon.appiconset")

guard let logo = NSImage(contentsOf: source) else {
    fatalError("无法读取 \(source.path)")
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(pixels) * 824 / 1024
    let inset = (CGFloat(pixels) - side) / 2
    logo.draw(in: NSRect(x: inset, y: inset, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale).write(to: output.appendingPathComponent(name))
        print(name)
    }
}
