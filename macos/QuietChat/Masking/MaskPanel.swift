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
        // 归属于所在桌面（不跟到其他桌面），允许出现在全屏应用的桌面上，不参与 ⌘` 窗口切换
        collectionBehavior = [.managed, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
