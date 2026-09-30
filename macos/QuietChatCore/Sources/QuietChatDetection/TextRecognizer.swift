// 文字识别：用 Vision 读出列表栏画面里的文字和位置，交给 QuietChatCore 的 ListRowParser 切分成行。
// 边界：只在内存中处理传入的图片，不落盘、不联网。识别出的文字可能是聊天名称，调用方不得写入日志。
// 输出为列表栏坐标：原点在图片左上角、y 向下，单位 pt。

import CoreGraphics
import QuietChatCore
import Vision

/// 列表画面的文字识别。
public enum TextRecognizer {
    /// 识别图片中的文字，结果按从上到下排列。
    ///
    /// 同步执行，一次约几百毫秒，不要在主线程调用。
    /// - Parameters:
    ///   - image: 列表栏的画面。
    ///   - scale: 图片中每 pt 对应的像素数（Retina 屏为 2），必须大于 0。
    ///   - customWords: 优先识别的词；传入白名单名称，可以提高这些名称的识别率。
    public static func recognize(_ image: CGImage, scale: CGFloat, customWords: [String]) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.customWords = customWords
        try VNImageRequestHandler(cgImage: image).perform([request])

        let width = CGFloat(image.width) / scale
        let height = CGFloat(image.height) / scale
        return (request.results ?? []).compactMap { observation -> TextBox? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision 返回归一化坐标，原点在左下角
            let box = observation.boundingBox
            return TextBox(
                text: candidate.string,
                rect: CGRect(
                    x: box.minX * width, y: (1 - box.maxY) * height,
                    width: box.width * width, height: box.height * height))
        }
        .sorted { $0.rect.minY < $1.rect.minY }
    }
}
