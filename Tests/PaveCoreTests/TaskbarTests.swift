import Testing

@testable import PaveCore

private let main = Screen(
    frame: Rect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1089))
private let external = Screen(
    frame: Rect(x: 1800, y: 0, width: 1920, height: 1080), visibleFrame: Rect(x: 1800, y: 0, width: 1920, height: 1040))

private func ids(_ raw: [UInt32]) -> [WindowID] { raw.map { WindowID($0) } }

private func w(
    _ id: UInt32, pid: PID, _ app: String, state: WindowState = .normal, x: Double = 100,
    subrole: String = "AXStandardWindow"
) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(id), pid: pid, appName: app, title: "t\(id)",
        frame: Rect(x: x, y: 100, width: 800, height: 600), state: state, subrole: subrole)
}

private let bundles: [PID: String] = [1: "com.brave.Browser", 2: "com.tinyspeck.slackmacgap", 3: "com.apple.finder"]

@Suite struct TaskbarModelTests {
    /// Opened in this order: Slack #10, Brave #20, Finder #30, Brave #40.
    private let windows = [
        w(40, pid: 1, "Brave"), w(10, pid: 2, "Slack"), w(30, pid: 3, "Finder"), w(20, pid: 1, "Brave"),
    ]

    private func model(_ ws: [WindowSnapshot]) -> TaskbarModel {
        var m = TaskbarModel()
        m.update(windows: ws)
        return m
    }

    private func items(
        _ ws: [WindowSnapshot], pinned: [String] = [], grouping: TaskbarGrouping = .never,
        width: Double = 1500, active: WindowID? = nil, screen: Screen = main,
        hidden: Set<WindowID> = []
    ) -> (items: [TaskbarItem], overflow: Int) {
        model(ws).items(
            windows: ws, on: screen, screens: [main, external], active: active, bundleIDs: bundles,
            pinned: pinned, grouping: grouping, width: width, hidden: hidden)
    }

    @Test func windowsOfOneAppSitTogetherInOpeningOrder() {
        let result = items(windows).items
        // Slack first (its window opened first), then Brave ×2 together, then Finder.
        #expect(result.map(\.windowIDs) == [[WindowID(10)], [WindowID(20)], [WindowID(40)], [WindowID(30)]])
        #expect(result.allSatisfy { !$0.isPinned })
    }

    @Test func orderIsStableWhenFocusChangesAndNewWindowsGoLast() {
        var m = model(windows)
        let more = windows + [w(5, pid: 2, "Slack")]  // a lower ID, but opened last
        m.update(windows: more)
        #expect(m.openOrder == ids([10, 20, 30, 40, 5]))
        // Closing a window just removes it.
        m.update(windows: more.filter { $0.id != WindowID(20) })
        #expect(m.openOrder == ids([10, 30, 40, 5]))
    }

    @Test func pinnedAppsComeFirstAndTheirWindowsTakeTheSlot() {
        let result = items(windows, pinned: ["com.apple.finder", "com.apple.Safari"]).items
        #expect(
            result.map(\.app) == [
                "com.apple.finder", "com.apple.Safari", "com.tinyspeck.slackmacgap", "com.brave.Browser",
                "com.brave.Browser",
            ])
        #expect(result[0].kind == .window(WindowID(30)) && result[0].isPinned)
        #expect(result[1].kind == .pinned && result[1].appName == nil)
    }

    @Test func alwaysGivesOneEntryPerApp() {
        let result = items(windows, grouping: .always, active: WindowID(40)).items
        #expect(result.map(\.kind) == [.group([WindowID(10)]), .group(ids([20, 40])), .group([WindowID(30)])])
        #expect(result.map(\.isActive) == [false, true, false])
    }

    @Test func whenFullCombinesBeforeTitlesGetUnreadable() {
        // 4 window entries at the 110 pt readable width = 440 pt: nothing to combine.
        #expect(items(windows, grouping: .whenFull, width: 440).items.count == 4)
        // 400 pt would squeeze them to 100 pt each: Brave (2 windows) is combined first.
        let combined = items(windows, grouping: .whenFull, width: 400).items
        #expect(combined.map(\.kind) == [.window(WindowID(10)), .group(ids([20, 40])), .window(WindowID(30))])
        // 100 pt: Slack (56) + Brave group (44) fit exactly; Finder overflows.
        let tight = items(windows, grouping: .whenFull, width: 100)
        #expect(tight.items.count == 2 && tight.overflow == 1)
    }

    @Test func theLineAfterPinnedAppsTakesItsRoom() {
        // Finder pinned, then Slack and Brave ×2: 4 × 56 + 10 (line) = 234.
        let fits = items(windows, pinned: ["com.apple.finder"], grouping: .never, width: 234)
        #expect(fits.overflow == 0)
        let short = items(windows, pinned: ["com.apple.finder"], grouping: .never, width: 230)
        #expect(short.overflow == 1)
    }

    @Test func eachScreenShowsItsWindowsAndDialogsOrParkedWindowsAreLeftOut() {
        let ws = windows + [w(50, pid: 1, "Brave", x: 2000), w(60, pid: 3, "Finder", subrole: "AXDialog")]
        #expect(items(ws, screen: external).items.map(\.windowIDs) == [[WindowID(50)]])
        let onMain = items(ws, hidden: [WindowID(10)]).items.flatMap(\.windowIDs)
        #expect(!onMain.contains(WindowID(60)) && !onMain.contains(WindowID(10)) && !onMain.contains(WindowID(50)))
    }

    @Test func minimizedWindowsAreDimmedAndKeyedByPIDWithoutBundleID() {
        let ws = [w(1, pid: 1, "Brave", state: .minimized), w(2, pid: 99, "Tool")]
        let result = items(ws).items
        #expect(result.map(\.isDimmed) == [true, false])
        #expect(result[1].app == "pid:99")
    }
}

@Suite struct TaskbarConfigTests {
    @Test func taskbarSettingsParse() throws {
        let (config, warnings) = try PaveConfig.parse(
            "[taskbar]\ngrouping = \"when_full\"\npinned = [\"com.apple.finder\", \"com.brave.Browser\", \"com.apple.finder\"]"
        )
        #expect(warnings.isEmpty)
        #expect(config.taskbarGrouping == .whenFull)
        #expect(config.taskbarPinned == ["com.apple.finder", "com.brave.Browser"])
        #expect(PaveConfig.default.taskbarGrouping == .never && PaveConfig.default.taskbarPinned.isEmpty)
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[taskbar]\ngrouping = \"sometimes\"") }
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[taskbar]\npinned = [1]") }
    }
}

@Suite struct TaskbarOverlapTests {
    // Built-in screen with the Dock hidden: usable area 40…1129, bar 1129…1169.
    let usable = Rect(x: 0, y: 40, width: 1800, height: 1089)

    @Test func zoomedWindowsStopAtTheBar() {
        // Native zoom down to the screen edge.
        #expect(
            TaskbarOverlap.fix(Rect(x: 0, y: 40, width: 1800, height: 1129), usable: usable)
                == Rect(x: 0, y: 40, width: 1800, height: 1089))
        // Already above the bar (or within 1 pt): left alone.
        #expect(TaskbarOverlap.fix(Rect(x: 0, y: 40, width: 1800, height: 1089), usable: usable) == nil)
        #expect(TaskbarOverlap.fix(Rect(x: 0, y: 40, width: 1800, height: 1090), usable: usable) == nil)
    }

    @Test func aWindowMostlyInTheBarIsMovedUp() {
        #expect(
            TaskbarOverlap.fix(Rect(x: 100, y: 1100, width: 600, height: 400), usable: usable)
                == Rect(x: 100, y: 729, width: 600, height: 400))
        // Another screen's window is not this bar's business.
        #expect(TaskbarOverlap.fix(Rect(x: 2000, y: 900, width: 600, height: 400), usable: usable) == nil)
    }

    @Test func overlapRuleParses() throws {
        let config = try PaveConfig.parse(
            "[apps.\"com.example\"]\ntaskbar-overlap = \"allow\"\n[taskbar]\nhide-dock = true"
        ).config
        #expect(config.rule(for: "com.example").taskbarOverlap)
        #expect(config.taskbarHideDock)
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[apps.\"x\"]\ntaskbar-overlap = \"maybe\"") }
    }
}
