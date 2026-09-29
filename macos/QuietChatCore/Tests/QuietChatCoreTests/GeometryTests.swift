import CoreGraphics
import Testing
@testable import QuietChatCore

struct GlobalCoordinatesTests {
    @Test func flipsAroundPrimaryScreenHeight() {
        // 主显示器高 1080：Quartz 中顶边 y=100、高 200 的矩形，在 Cocoa 中底边 y = 1080 - 300
        let quartz = CGRect(x: 10, y: 100, width: 50, height: 200)
        #expect(GlobalCoordinates.flip(quartz, primaryScreenHeight: 1080) == CGRect(x: 10, y: 780, width: 50, height: 200))
    }

    @Test func flipIsItsOwnInverse() {
        // 包括位于主显示器上方的副显示器（Quartz y 为负）
        for rect in [CGRect(x: 0, y: 0, width: 1920, height: 30), CGRect(x: -1512, y: -982, width: 300, height: 400)] {
            let roundTrip = GlobalCoordinates.flip(GlobalCoordinates.flip(rect, primaryScreenHeight: 1080), primaryScreenHeight: 1080)
            #expect(roundTrip == rect)
        }
    }
}

struct ListColumnLayoutTests {
    let window = CGRect(x: 100, y: 50, width: 1000, height: 800)

    @Test func columnStartsAfterSidebarAndReachesWindowBottom() {
        let layout = ListColumnLayout(leftInset: 64, topInset: 30, width: 280)
        #expect(layout.rect(in: window) == CGRect(x: 164, y: 80, width: 280, height: 770))
    }

    @Test func columnIsClippedToNarrowWindow() {
        let narrow = CGRect(x: 100, y: 50, width: 200, height: 800)
        #expect(ListColumnLayout.default.rect(in: narrow) == CGRect(x: 164, y: 50, width: 136, height: 800))
    }

    @Test func columnOutsideWindowYieldsNil() {
        let tiny = CGRect(x: 100, y: 50, width: 50, height: 800)
        #expect(ListColumnLayout.default.rect(in: tiny) == nil)
    }

    @Test func calibratedRectIsStoredRelativeToWindow() {
        let layout = ListColumnLayout(calibratedRect: CGRect(x: 170, y: 60, width: 250, height: 500), in: window)
        #expect(layout == ListColumnLayout(leftInset: 70, topInset: 10, width: 250))
        #expect(layout.rect(in: window.offsetBy(dx: 300, dy: 200)) == CGRect(x: 470, y: 260, width: 250, height: 790))
    }

    @Test func calibrationRoundsToWholePoints() {
        // 拖动时的鼠标坐标带小数
        let layout = ListColumnLayout(calibratedRect: CGRect(x: 170.4, y: 60.6, width: 250.3, height: 500), in: window)
        #expect(layout == ListColumnLayout(leftInset: 70, topInset: 11, width: 251))
    }

    /// 回归：旧配置里的小数布局（真实数据，微信在左侧副屏上）会让遮罩右边缘留下一条半透明细线。
    @Test func fractionalLayoutYieldsWholePointRect() throws {
        let layout = ListColumnLayout(leftInset: 58.21875, topInset: 251, width: 236.78125)
        let windowOnLeftDisplay = CGRect(x: -1176, y: 110, width: 935, height: 807)
        let rect = try #require(layout.rect(in: windowOnLeftDisplay))
        #expect(rect == CGRect(x: -1118, y: 361, width: 237, height: 556))
        #expect(rect == rect.integral)
    }

    @Test func calibrationIsClampedToWindowAndMinimumSize() {
        let outside = ListColumnLayout(calibratedRect: CGRect(x: 0, y: 0, width: 2000, height: 100), in: window)
        #expect(outside == ListColumnLayout(leftInset: 0, topInset: 0, width: 1000))

        let sliver = ListColumnLayout(calibratedRect: CGRect(x: 300, y: 50, width: 5, height: 100), in: window)
        #expect(sliver.width == ListColumnLayout.minimumLength)

        let belowBottom = ListColumnLayout(calibratedRect: CGRect(x: 200, y: 2000, width: 100, height: 100), in: window)
        #expect(belowBottom.topInset == 800 - ListColumnLayout.minimumLength)
    }
}

struct MaskPlannerTests {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let layout = ListColumnLayout(leftInset: 64, topInset: 0, width: 280)

    @Test func maskCoversColumnWithoutOccluders() {
        let plan = MaskPlanner.plan(windowFrame: window, layout: layout, occluders: [])
        #expect(plan == MaskPlan(maskRect: CGRect(x: 64, y: 0, width: 280, height: 800), holes: []))
    }

    @Test func occluderOverlapBecomesHoleInLocalCoordinates() throws {
        let occluder = CGRect(x: 300, y: 100, width: 500, height: 200)
        let plan = try #require(MaskPlanner.plan(windowFrame: window, layout: layout, occluders: [occluder, CGRect(x: 600, y: 0, width: 50, height: 50)]))
        #expect(plan.holes == [CGRect(x: 300, y: 100, width: 44, height: 200)])
        #expect(plan.holesInMaskCoordinates == [CGRect(x: 236, y: 100, width: 44, height: 200)])
    }

    @Test func holesAreWholePointsInsideMask() throws {
        let occluder = CGRect(x: 300.5, y: 100.25, width: 500, height: 200)
        let plan = try #require(MaskPlanner.plan(windowFrame: window, layout: layout, occluders: [occluder]))
        #expect(plan.holes == [CGRect(x: 300, y: 100, width: 44, height: 201)])
    }

    @Test func showsWhenWindowIsVisible() {
        let snapshot = WindowSnapshot(frame: window, presence: .visible)
        let decision = MaskPlanner.decide(snapshot: snapshot, layout: layout, maskIsOnActiveSpace: false)
        #expect(decision == .show(MaskPlan(maskRect: CGRect(x: 64, y: 0, width: 280, height: 800), holes: [])))
    }

    @Test func hidesWithoutWindowOrWhenClosed() {
        #expect(MaskPlanner.decide(snapshot: nil, layout: layout, maskIsOnActiveSpace: true) == .hide)
        let closed = WindowSnapshot(frame: window, presence: .closed)
        #expect(MaskPlanner.decide(snapshot: closed, layout: layout, maskIsOnActiveSpace: false) == .hide)
    }

    @Test func windowOnOtherSpaceHidesOnlyIfMaskIsOnActiveSpace() {
        let elsewhere = WindowSnapshot(frame: window, presence: .onOtherSpace)
        // 遮罩在当前桌面而窗口不在：微信被移到了别的桌面
        #expect(MaskPlanner.decide(snapshot: elsewhere, layout: layout, maskIsOnActiveSpace: true) == .hide)
        // 两者都不在当前桌面：用户切到了别的桌面，遮罩留在微信所在的桌面
        #expect(MaskPlanner.decide(snapshot: elsewhere, layout: layout, maskIsOnActiveSpace: false) == .keep)
    }

    @Test func hidesWhenColumnDoesNotFitWindow() {
        let tiny = WindowSnapshot(frame: CGRect(x: 0, y: 0, width: 50, height: 800), presence: .visible)
        #expect(MaskPlanner.decide(snapshot: tiny, layout: layout, maskIsOnActiveSpace: true) == .hide)
    }
}

struct WindowPresenceTests {
    @Test func onScreenWindowIsVisible() {
        #expect(WindowPresence.classify(isOnScreen: true, isExplicitlyHidden: false, spaceCount: 1) == .visible)
    }

    @Test func minimizedOrHiddenWindowIsClosed() {
        #expect(WindowPresence.classify(isOnScreen: false, isExplicitlyHidden: true, spaceCount: 1) == .closed)
    }

    @Test func offScreenWindowStillOnASpaceIsElsewhere() {
        #expect(WindowPresence.classify(isOnScreen: false, isExplicitlyHidden: false, spaceCount: 1) == .onOtherSpace)
    }

    @Test func offScreenWindowOnNoSpaceIsClosed() {
        #expect(WindowPresence.classify(isOnScreen: false, isExplicitlyHidden: false, spaceCount: 0) == .closed)
    }

    @Test func unknownSpacesCountAsClosed() {
        // 私有接口不可用：宁可多锁一次
        #expect(WindowPresence.classify(isOnScreen: false, isExplicitlyHidden: false, spaceCount: nil) == .closed)
    }
}

struct MainWindowSelectorTests {
    let standard = "AXStandardWindow"

    @Test func prefersWindowTitledWithAppName() {
        let candidates = [
            WindowCandidate(title: "文件传输助手", subrole: standard, size: CGSize(width: 1200, height: 900)),
            WindowCandidate(title: "微信", subrole: standard, size: CGSize(width: 1000, height: 700)),
        ]
        #expect(MainWindowSelector.selectMainWindow(from: candidates) == 1)
    }

    @Test func fallsBackToLargestStandardWindow() {
        let candidates = [
            WindowCandidate(title: nil, subrole: standard, size: CGSize(width: 500, height: 400)),
            WindowCandidate(title: nil, subrole: "AXDialog", size: CGSize(width: 1600, height: 1000)),
            WindowCandidate(title: "", subrole: standard, size: CGSize(width: 1036, height: 787)),
        ]
        #expect(MainWindowSelector.selectMainWindow(from: candidates) == 2)
    }

    @Test func ignoresSmallOrNonStandardWindows() {
        let candidates = [
            WindowCandidate(title: "微信", subrole: standard, size: CGSize(width: 100, height: 30)),
            WindowCandidate(title: "微信", subrole: "AXFloatingWindow", size: CGSize(width: 1000, height: 700)),
        ]
        #expect(MainWindowSelector.selectMainWindow(from: candidates) == nil)
    }
}
