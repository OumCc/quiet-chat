// 遮罩窗口：无边框、点击时不激活本应用的浮动面板。
// 始终处于 floating 层级、高于所有普通窗口，所以微信被点击、窗口被提到最前时也盖不过它；
// 压在微信之上的其他窗口，由 MaskView 在对应区域开洞让出（见 QuietChatCore.MaskPlanner）。

import AppKit

final class MaskPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isFloatingPanel = true
        // 本应用几乎从不处于激活状态，面板不能随"应用失去激活"而隐藏
        hidesOnDeactivate = false
        // 透明像素不接收点击：洞里的点击会落到下面的窗口
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // transient：不出现在调度中心（managed 会显示成一个单独的窗口），仍然只属于一个桌面；
        // moveToActiveSpace：重新显示时落到当前桌面（微信被移到别的桌面、进入全屏时需要）；
        // 允许出现在全屏应用的桌面上，不参与 ⌘` 窗口切换
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// 是否出现在所有桌面上：跟随微信主窗口的"分配给所有桌面"设置。
    /// 否则遮罩只属于微信所在的桌面，切换桌面时两者一起滑入滑出。
    var joinsAllSpaces: Bool {
        get { collectionBehavior.contains(.canJoinAllSpaces) }
        set {
            guard newValue != joinsAllSpaces else { return }
            // canJoinAllSpaces 与 moveToActiveSpace 互斥
            if newValue {
                collectionBehavior.remove(.moveToActiveSpace)
                collectionBehavior.insert(.canJoinAllSpaces)
            } else {
                collectionBehavior.remove(.canJoinAllSpaces)
                collectionBehavior.insert(.moveToActiveSpace)
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
