// 辅助功能接口（AXUIElement）的薄封装：读取常用属性，并把窗口元素映射到窗口服务器的窗口编号。

import ApplicationServices
import CoreGraphics

// 私有接口：由辅助功能窗口元素取得 CGWindowID。公开接口里没有等价物，
// Rectangle、AltTab、yabai 等窗口工具长期依赖它；取不到时调用方退回按外框匹配。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    /// 读取属性原始值，同时返回错误码，便于区分"元素已失效"和"属性不存在"。
    func attributeValue(_ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    func string(_ name: String) -> String? {
        attributeValue(name).value as? String
    }

    func bool(_ name: String) -> Bool? {
        attributeValue(name).value as? Bool
    }

    /// 应用元素下的全部窗口；读取失败时为空。
    var windows: [AXUIElement] {
        (attributeValue(kAXWindowsAttribute).value as? [AXUIElement]) ?? []
    }

    /// 窗口外框（Quartz 全局坐标）。
    var frame: CGRect? {
        guard let origin: CGPoint = axValue(kAXPositionAttribute, type: .cgPoint, initial: .zero),
              let size: CGSize = axValue(kAXSizeAttribute, type: .cgSize, initial: .zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var size: CGSize? {
        axValue(kAXSizeAttribute, type: .cgSize, initial: .zero)
    }

    /// 对应的窗口服务器窗口编号；元素不是窗口或私有接口不可用时为 nil。
    var windowID: CGWindowID? {
        var windowID: CGWindowID = 0
        return _AXUIElementGetWindow(self, &windowID) == .success && windowID != 0 ? windowID : nil
    }

    private func axValue<T: BitwiseCopyable>(_ name: String, type: AXValueType, initial: T) -> T? {
        guard let value = attributeValue(name).value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = initial
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), type, &result) ? result : nil
    }
}
