// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import PaveCore

@Test func pcPresetShortcutsShowTheKeysPressed() {
    // ⌃⌥← as macOS receives it is ⌥⌘← on the keys (⌘ next to the space bar).
    #expect(Hotkey(123, [.control, .option]).pressedWithPCPreset.description == "⌥⌘←")
    #expect(Hotkey(48, .control).pressedWithPCPreset.description == "⌘Tab")
    #expect(Hotkey(8, .command).pressedWithPCPreset == Hotkey(8, .control))
    #expect(Hotkey(49, .shift).pressedWithPCPreset == Hotkey(49, .shift))
}

@Suite struct TOMLTests {
    @Test func parsesTheSupportedSubset() throws {
        let (root, lines) = try TOML.parse(
            """
            # comment
            top = "a \\"quoted\\" value" # trailing comment
            [section]
            flag = true
            count = 1_000
            literal = 'C:\\path'
            list = [
              "x", # inside
              'y',
            ]
            [section.sub]
            "quoted key" = false
            """)
        #expect(root["top"] == .string("a \"quoted\" value"))
        guard case .table(let section)? = root["section"] else {
            Issue.record("no section")
            return
        }
        #expect(section["flag"] == .bool(true))
        #expect(section["count"] == .integer(1000))
        #expect(section["literal"] == .string("C:\\path"))
        #expect(section["list"] == .array([.string("x"), .string("y")]))
        #expect(section["sub"] == .table(["quoted key": .bool(false)]))
        #expect(lines["section.flag"] == 4)
    }

    @Test(arguments: [
        ("a = 1\na = 2", 2, "defined twice"),
        ("[t]\n[t]", 2, "defined twice"),
        ("a = {x = 1}", 1, "inline tables"),
        ("a = bare", 1, "need quotes"),
        ("a = \"open", 1, "unterminated"),
        ("a = 1 2", 1, "after value"),
        ("a.b = 1", 1, "dotted keys"),
        ("[[t]]", 1, "arrays of tables"),
        ("\n\nx", 3, "expected '='"),
    ])
    func reportsErrorsWithTheirLine(text: String, line: Int, fragment: String) {
        #expect {
            try TOML.parse(text)
        } throws: { error in
            guard let error = error as? TOMLError else { return false }
            return error.line == line && error.message.contains(fragment)
        }
    }
}

@Suite struct HotkeyNameTests {
    @Test func parsesShortcuts() throws {
        #expect(try Hotkey.parse("ctrl+left") == Hotkey(Hotkey.Key.leftArrow, .control))
        #expect(try Hotkey.parse(" Ctrl + Shift + 2 ") == Hotkey(Hotkey.Key.digits[1], [.control, .shift]))
        #expect(try Hotkey.parse("alt+cmd+tab") == Hotkey(48, [.option, .command]))
        #expect(try Hotkey.parse("none") == nil)
        #expect(try Hotkey.parse("") == nil)
    }

    @Test(arguments: ["left", "ctrl+", "hyper+left", "ctrl+nope"])
    func rejectsInvalidShortcuts(text: String) {
        #expect(throws: Hotkey.ParseError.self) { try Hotkey.parse(text) }
    }

    @Test func configNameRoundTrips() throws {
        for case let hotkey? in PaveConfig.defaultBindings.values {
            #expect(try Hotkey.parse(hotkey.configName) == hotkey)
        }
        #expect(Hotkey(53, .control).configName == "ctrl+escape")
        #expect(Hotkey(Hotkey.Key.upArrow, [.control, .shift]).description == "⌃⇧↑")
    }
}

@Suite struct PaveConfigTests {
    @Test func templateParsesToTheDefaults() throws {
        let (config, warnings) = try PaveConfig.parse(PaveConfig.template)
        #expect(config == .default)
        #expect(warnings.isEmpty)
    }

    @Test func emptyFileGivesTheDefaults() throws {
        #expect(try PaveConfig.parse("").config == .default)
    }

    @Test func workspaceHotkeysAreOnlyGrabbedWhenEnabled() throws {
        let off = PaveConfig.default.activeBindings
        #expect(off.count == 8)  // ⌃Tab, ⌃←→↑↓, ⌃⇧←→, ⌃⇧A (arrangements)
        #expect(off[Hotkey(Hotkey.Key.digits[0], .control)] == nil)

        let on = try PaveConfig.parse("[workspaces]\nenabled = true").config.activeBindings
        #expect(on.count == 8 + 18 + 9)  // + focus ×4, resize ×4, toggle-floating (M4)
        #expect(on[Hotkey(49, [.control, .shift])] == .toggleFloating)
        #expect(on[Hotkey(Hotkey.Key.digits[2], [.control, .shift])] == .moveToWorkspace(3))
    }

    @Test func bindingsOverrideOnlyWhatTheyList() throws {
        let (config, _) = try PaveConfig.parse(
            """
            [bindings]
            snap-left = "ctrl+cmd+left"
            maximize = "none"
            """)
        #expect(config.bindings[.layout(.snapLeft)] == Hotkey(Hotkey.Key.leftArrow, [.control, .command]))
        #expect(config.bindings[.layout(.maximize)] == .some(nil))
        #expect(config.bindings[.layout(.snapRight)] == PaveConfig.defaultBindings[.layout(.snapRight)])
        #expect(config.activeBindings.count == 7)
    }

    @Test func unknownKeysAreWarningsNotErrors() throws {
        let (config, warnings) = try PaveConfig.parse(
            """
            [switcher]
            scope = "all"
            colour = "blue"
            [bindings]
            snap-middle = "ctrl+m"
            [start-menu]
            """)
        #expect(config.switcherScope == .all)
        #expect(warnings.map(\.line) == [6, 3, 5])
        #expect(warnings.allSatisfy { $0.message.contains("ignored") })
    }

    @Test(arguments: [
        ("[workspaces]\nenabled = \"yes\"", 2, "true or false"),
        ("[switcher]\nscope = \"everything\"", 2, "\"workspace\", \"screen\" or \"all\""),
        ("[bindings]\nrestore = 3", 2, "must be a string"),
        ("[bindings]\nrestore = \"down\"", 2, "at least one modifier"),
        ("[bindings]\nsnap-left = \"ctrl+right\"", 2, "bound to both"),
        ("workspaces = 1", 1, "must be a [workspaces] table"),
        ("[bindings\n", 1, "']'"),
        ("[keyboard]\npreset = \"mac\"", 2, "keyboard.preset must be"),
        ("[keyboard]\nskip = [\"logitech\"]", 2, "keyboard.skip must be"),
        ("[keyboard]\nremap = \"yes\"", 2, "true or false"),
    ])
    func invalidFilesAreRejectedWithTheLine(text: String, line: Int, fragment: String) {
        #expect {
            try PaveConfig.parse(text)
        } throws: { error in
            guard let problem = error as? PaveConfig.Problem else { return false }
            return problem.line == line && problem.message.contains(fragment)
        }
    }

    @Test func everyActionHasAUniqueName() {
        let names = HotkeyAction.all.map(\.configName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { HotkeyAction(configName: $0) != nil })
    }
}

@Suite struct KeyRemapTests {
    let builtIn = KeyRemap.Keyboard(vendorID: 0, productID: 0, builtIn: true, name: "Apple Internal Keyboard")
    let logitech = KeyRemap.Keyboard(vendorID: 1133, productID: 45944, builtIn: false, name: "MX Keys")

    @Test func pcPresetMatchesTheReadmeTable() {
        let common: [KeyRemap.Mapping] = [.init(.leftCommand, .leftControl), .init(.rightCommand, .rightOption)]
        // Built-in: no §/< swap (A/B tested: macOS already places ² and <).
        #expect(
            KeyRemap.mappings(for: builtIn, preset: .pc)
                == common + [.init(.fn, .leftCommand), .init(.leftControl, .fn)])
        // No §/< swap on external keyboards either (tested on a Logitech MX Keys S).
        #expect(KeyRemap.mappings(for: logitech, preset: .pc) == common + [.init(.leftControl, .leftCommand)])
        #expect(KeyRemap.mappings(for: logitech, preset: .none).isEmpty)
    }

    @Test func hidutilArgumentsTargetTheWholeDevice() {
        #expect(builtIn.matching == #"{"Built-In":1}"#)
        var located = builtIn
        located.locationID = 282
        #expect(located.matching == #"{"Built-In":1,"LocationID":282}"#)
        #expect(logitech.matching == #"{"VendorID":1133,"ProductID":45944}"#)
        #expect(logitech.configID == "1133:45944")
        #expect(KeyRemap.hidutilProperty([]) == #"{"UserKeyMapping":[]}"#)
        #expect(
            KeyRemap.hidutilProperty([.init(.fn, .leftCommand)])
                == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":1095216660483,"HIDKeyboardModifierMappingDst":30064771299}]}"#
        )
    }

    @Test func keyboardSettingsParse() throws {
        let (config, warnings) = try PaveConfig.parse(
            "[keyboard]\nremap = false\npreset = \"none\"\nskip = [\"built-in\", \"1133:45944\"]")
        #expect(warnings.isEmpty)
        #expect(config.keyboardRemap == false)
        #expect(config.keyboardPreset == .none)
        #expect(config.keyboardSkip == ["built-in", "1133:45944"])
        #expect(PaveConfig.default.keyboardRemap && PaveConfig.default.keyboardPreset == .pc)
    }
}

@Suite struct ConfigEditTests {
    @Test func replacesTheLineAndKeepsEverythingElse() throws {
        let text = "# mine\n[workspaces]\n# comment\n  enabled = false # off for now\n\n[switcher]\nenabled = true\n"
        let edited = ConfigEdit.set("workspaces", "enabled", to: "true", in: text)
        #expect(
            edited == "# mine\n[workspaces]\n# comment\n  enabled = true # off for now\n\n[switcher]\nenabled = true\n")
        #expect(try PaveConfig.parse(edited).config.workspacesEnabled)
    }

    @Test func commentedOutKeysAreNotTheKey() {
        let text = "[keyboard]\n# remap = true\npreset = \"pc\" # a # in a comment\n"
        #expect(
            ConfigEdit.set("keyboard", "remap", to: "false", in: text)
                == "[keyboard]\nremap = false\n# remap = true\npreset = \"pc\" # a # in a comment\n")
        #expect(
            ConfigEdit.set("keyboard", "preset", to: "\"none\"", in: text)
                == "[keyboard]\n# remap = true\npreset = \"none\" # a # in a comment\n")
    }

    @Test func missingTableIsAppended() throws {
        let edited = ConfigEdit.set("keyboard", "remap", to: "false", in: "[switcher]\nscope = \"all\"")
        #expect(edited == "[switcher]\nscope = \"all\"\n\n[keyboard]\nremap = false\n")
        #expect(try PaveConfig.parse(edited).config.keyboardRemap == false)
        // Every toggle on the template gives a valid file.
        for (table, key) in [("workspaces", "enabled"), ("keyboard", "remap")] {
            let config = try PaveConfig.parse(ConfigEdit.set(table, key, to: "true", in: PaveConfig.template)).config
            #expect(config.keyboardRemap)
        }
    }
}

@Suite struct AppRuleTests {
    private func window(_ subrole: String = "AXStandardWindow") -> WindowSnapshot {
        WindowSnapshot(
            id: WindowID(1), pid: 1, appName: "App", title: "", frame: Rect(x: 0, y: 0, width: 10, height: 10),
            state: .normal, subrole: subrole)
    }

    @Test func rulesParseByBundleID() throws {
        let (config, warnings) = try PaveConfig.parse(
            """
            [apps."com.microsoft.teams2"]
            ignore = true
            [apps."com.jetbrains.intellij"]
            drag-snap = false
            colour = "red"
            """)
        #expect(config.rule(for: "com.microsoft.teams2") == AppRule(ignore: true))
        #expect(config.rule(for: "com.jetbrains.intellij") == AppRule(dragSnap: false))
        #expect(config.rule(for: "com.apple.TextEdit") == AppRule())
        #expect(config.rule(for: nil) == AppRule())
        #expect(warnings.count == 1 && warnings[0].line == 5)
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[apps.\"x\"]\nignore = 1") }
    }

    @Test func dialogsAreNeverPlacedAndRulesApply() {
        #expect(AppRule().refusal(for: window(), via: .drag) == nil)
        #expect(AppRule().refusal(for: window("AXDialog"), via: .hotkey) != nil)
        #expect(AppRule(ignore: true).refusal(for: window(), via: .hotkey) == "ignored by its app rule")
        #expect(AppRule(dragSnap: false).refusal(for: window(), via: .hotkey) == nil)
        #expect(AppRule(dragSnap: false).refusal(for: window(), via: .drag) == "drag-snap off by its app rule")
    }
}

@Suite struct AppWorkspaceRuleTests {
    @Test func workspaceRuleParses() throws {
        let config = try PaveConfig.parse(
            """
            [apps."com.tinyspeck.slackmacgap"]
            workspace = 3
            """
        ).config
        #expect(config.rule(for: "com.tinyspeck.slackmacgap").workspace == 3)
        #expect(config.rule(for: "com.tinyspeck.slackmacgap").summary == "workspace 3")
    }

    @Test(arguments: ["workspace = 0", "workspace = 10", "workspace = \"3\""])
    func invalidWorkspaceRuleIsRejected(line: String) {
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[apps.\"a.b\"]\n\(line)") }
    }
}

@Suite struct TilingConfigTests {
    @Test func tilingSettingsParse() throws {
        let config = try PaveConfig.parse(
            """
            [workspaces]
            tiling = [2, 3]
            gaps = 0
            [apps."com.apple.systempreferences"]
            tile = false
            """
        ).config
        #expect(config.tilingWorkspaces == [2, 3])
        #expect(config.tilingGaps == 0)
        #expect(!config.rule(for: "com.apple.systempreferences").tile)
        #expect(PaveConfig.default.tilingGaps == 8 && PaveConfig.default.tilingWorkspaces.isEmpty)
    }

    @Test(arguments: ["tiling = [0]", "tiling = [10]", "tiling = 2", "gaps = 100", "gaps = \"8\""])
    func invalidTilingSettingsAreRejected(line: String) {
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[workspaces]\n\(line)") }
    }

    /// Errors reach the log, `pave config` and Settings: never the text of a
    /// string (a workspace name may be private).
    @Test(arguments: [
        "[workspaces]\nnames = [\"Secret\", 3]", "[workspaces]\nnames = Secret", "[switcher]\nscope = \"Secret\"",
        "[workspaces]\nenabled = \"Secret\"", "[updates]\nsource = \"Secret\"",
    ])
    func errorsNeverShowStrings(text: String) {
        do {
            _ = try PaveConfig.parse(text)
            Issue.record("accepted: \(text)")
        } catch {
            #expect(!error.description.contains("Secret"), "\(error)")
        }
    }

    @Test func newActionsHaveConfigNames() {
        #expect(HotkeyAction(configName: "focus-left") == .focus(.left))
        #expect(HotkeyAction(configName: "resize-down") == .resize(.down))
        #expect(HotkeyAction(configName: "toggle-floating") == .toggleFloating)
    }
}

@Suite struct ConfigEditRemovalTests {
    private let text = """
        [workspaces]
        enabled = true
        tiling = [2] # tiled

        [apps."com.tinyspeck.slackmacgap"]
        # Slack on 4
        workspace = 4

        [apps."com.apple.finder"]
        ignore = true
        """

    @Test func removesAKey() throws {
        let edited = ConfigEdit.remove("workspaces", "tiling", in: text)
        #expect(!edited.contains("tiling"))
        #expect(edited.contains("enabled = true"))
        #expect(ConfigEdit.remove("workspaces", "gaps", in: text) == text)
        _ = try PaveConfig.parse(edited)
    }

    @Test func removesAnAppRuleAndOnlyIt() throws {
        let edited = ConfigEdit.removeTable(ConfigEdit.appTable("com.tinyspeck.slackmacgap"), in: text)
        #expect(!edited.contains("slack") && !edited.contains("workspace = 4"))
        #expect(edited.contains("[apps.\"com.apple.finder\"]\nignore = true"))
        #expect(edited.contains("tiling = [2] # tiled\n\n[apps"))
        let (config, _) = try PaveConfig.parse(edited)
        #expect(config.appRules.keys.sorted() == ["com.apple.finder"])
        let last = ConfigEdit.removeTable(ConfigEdit.appTable("com.apple.finder"), in: edited)
        #expect(try PaveConfig.parse(last).0.appRules.isEmpty)
    }

    @Test func valuesAreValidTOML() throws {
        let names = ConfigEdit.list(["Web", "Code \"perso\"", "a\\b"])
        let edited = ConfigEdit.set("workspaces", "names", to: names, in: text)
        let (config, _) = try PaveConfig.parse(edited)
        #expect(config.workspaceNames == ["Web", "Code \"perso\"", "a\\b"])
        #expect(ConfigEdit.list([2, 3]) == "[2, 3]")
        let rule = ConfigEdit.set(ConfigEdit.appTable("com.example.app"), "tile", to: "false", in: text)
        #expect(try PaveConfig.parse(rule).0.appRules["com.example.app"]?.tile == false)
    }
}

@Suite struct ProfileRuleTests {
    private static let text = """
        [apps."com.brave.Browser"]
        workspace = 2
        [apps."com.brave.Browser".profiles]
        Work = 3
        "Home Work" = 5
        """

    @Test func profilesParseAndMatchTheTitleEnd() throws {
        let (config, warnings) = try PaveConfig.parse(Self.text)
        #expect(warnings.isEmpty)
        let rule = config.rule(for: "com.brave.Browser")
        #expect(rule.profiles == ["Work": 3, "Home Work": 5])
        #expect(rule.summary == "workspace 2, workspace by profile (2)")
        #expect(rule.workspaceChoice(title: "Page - Brave - Work") == .init(workspace: 3, byTitle: true))
        #expect(rule.workspaceChoice(title: "Page - Brave - Home Work") == .init(workspace: 5, byTitle: true))
        // Another profile, or no title yet: the app's workspace, and the title is looked at again.
        #expect(rule.workspaceChoice(title: "Page - Brave - Perso") == .init(workspace: 2, awaitsTitle: true))
        #expect(rule.workspaceChoice(title: "") == .init(workspace: 2, awaitsTitle: true))
        // In the page title only: not the profile.
        #expect(rule.profileWorkspace(title: "Work - Brave - Perso") == nil)
        #expect(AppRule().workspaceChoice(title: "x - Work") == .init())
    }

    @Test(arguments: ["Work = 0", "Work = \"3\"", "Work = 10"])
    func invalidProfileIsRejectedWithoutItsName(line: String) {
        do {
            _ = try PaveConfig.parse("[apps.\"com.brave.Browser\".profiles]\n\(line)")
            Issue.record("accepted")
        } catch {
            #expect(error.line == 2)
            #expect(!error.message.contains("Work"))
        }
    }
}

@Suite struct WorkspaceIconTests {
    @Test func iconsParse() {
        #expect(WorkspaceIcon("🌐") == .text("🌐"))
        #expect(WorkspaceIcon("✉️") == .text("✉️"))
        #expect(WorkspaceIcon("👩‍💻") == .text("👩‍💻"))  // one character, several scalars
        #expect(WorkspaceIcon("JS") == .text("JS"))
        #expect(WorkspaceIcon(" sf:globe ") == .symbol("globe"))
        #expect(
            WorkspaceIcon("sf:chevron.left.forwardslash.chevron.right")
                == .symbol("chevron.left.forwardslash.chevron.right"))
        for bad in ["", "Web", "sf:", "sf:a b", "sf:.globe", "sf:globe/x", "a\nb"] {
            #expect(WorkspaceIcon(bad) == nil)
        }
        #expect(WorkspaceIcon.isValid("") && !WorkspaceIcon.isValid("Mail"))
    }

    @Test func configListsIconsAndHidesThemInErrors() throws {
        let config = try PaveConfig.parse("[workspaces]\nicons = [\"🌐\", \"\", \"sf:envelope\"]").config
        #expect(config.workspaceIcons == ["🌐", "", "sf:envelope"])
        do {
            _ = try PaveConfig.parse("[workspaces]\nicons = [\"🌐\", \"Secret\"]")
            Issue.record("accepted")
        } catch {
            #expect(error.line == 2 && !error.message.contains("Secret"))
        }
    }

    @Test func indicatorCarriesTheIcons() {
        let screen = Screen(
            frame: Rect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: Rect(x: 0, y: 40, width: 1800, height: 1069))
        var ws = Workspaces()
        _ = ws.screensChanged([screen], windows: [])
        let items = WorkspaceIndicator.items(
            for: screen.id, primaryID: screen.id, state: ws, windows: [], icons: ["sf:globe", "x"])
        #expect(items.map(\.icon) == [.symbol("globe")])
        let none = WorkspaceIndicator.items(for: screen.id, primaryID: screen.id, state: ws, windows: [], icons: [""])
        #expect(none.map(\.icon) == [nil])
    }
}

@Suite struct TitleRuleTests {
    @Test(arguments: [
        ("*Work", "Inbox — Prism Work", true),
        ("*Work", "Inbox — Prism work", true),  // case ignored
        ("*Work", "Homework due", false),  // the whole title must match
        ("*pave*", "main.swift — Pavé — poc-pave", true),
        ("Re?ort", "Report", true),
        ("Re?ort", "Rport", false),
        ("*", "", true),
        ("a*b*c", "aXbYbZc", true),
        ("a*b*c", "aXbYbZ", false),
        ("Work", "Work", true),
    ])
    func globMatchesTheWholeTitle(pattern: String, title: String, expected: Bool) {
        #expect(TitlePattern.matches(pattern, title) == expected)
    }

    @Test func theMostSpecificPatternWinsWhateverTheOrder() {
        let patterns = ["*Work": 3, "*Home Work": 5, "*": 1]
        #expect(TitlePattern.best(patterns, title: "Notes Home Work") == 5)
        #expect(TitlePattern.best(patterns, title: "Notes Work") == 3)
        #expect(TitlePattern.best(patterns, title: "Notes") == 1)
        // Same weight: alphabetical, never the file's order.
        #expect(TitlePattern.best(["*a*": 2, "*b*": 4], title: "ab") == 2)
        #expect(TitlePattern.best([:], title: "x") == nil)
    }

    @Test func titlesComeAfterProfilesAndBeforeTheAppWorkspace() throws {
        let (config, warnings) = try PaveConfig.parse(
            """
            [apps."com.example.prism"]
            workspace = 2
            [apps."com.example.prism".profiles]
            Perso = 7
            [apps."com.example.prism".titles]
            "*Work" = 3
            "*Perso" = 4
            """)
        #expect(warnings.isEmpty)
        let rule = config.rule(for: "com.example.prism")
        #expect(rule.titles == ["*Work": 3, "*Perso": 4])
        #expect(rule.summary == "workspace 2, workspace by profile (1), workspace by title (2)")
        // No " - " needed: the Prism case.
        #expect(rule.workspaceChoice(title: "Prism Work") == .init(workspace: 3, byTitle: true))
        #expect(rule.workspaceChoice(title: "Page - Perso") == .init(workspace: 7, byTitle: true))
        #expect(rule.workspaceChoice(title: "Prism") == .init(workspace: 2, awaitsTitle: true))
        // Titles alone also wait for the title.
        let titlesOnly = try PaveConfig.parse("[apps.\"x\".titles]\n\"*A\" = 1").0.rule(for: "x")
        #expect(titlesOnly.workspaceChoice(title: "") == .init(awaitsTitle: true))
    }

    @Test func aTitlePatternCanShowAWindowOnEveryWorkspace() throws {
        let (config, warnings) = try PaveConfig.parse(
            """
            [apps."com.brave.Browser"]
            workspace = 2
            [apps."com.brave.Browser".titles]
            "Picture*" = "all"
            "*Work" = 3
            """)
        #expect(warnings.isEmpty)
        let rule = config.rule(for: "com.brave.Browser")
        #expect(rule.titles == ["Picture*": .everywhere, "*Work": 3])
        #expect(rule.workspaceChoice(title: "Picture in picture") == .init(byTitle: true, everywhere: true))
        #expect(rule.workspaceChoice(title: "Page - Work") == .init(workspace: 3, byTitle: true))
        #expect(rule.workspaceChoice(title: "Page") == .init(workspace: 2, awaitsTitle: true))
        #expect(TitleTarget.everywhere.toml == "\"all\"" && TitleTarget.workspace(4).toml == "4")
    }

    @Test func aProfileCannotBeShownEverywhere() {
        #expect(throws: PaveConfig.Problem.self) { try PaveConfig.parse("[apps.\"x\".profiles]\nWork = \"all\"") }
    }

    @Test(arguments: [
        "\"*Secret\" = 0", "\"*Secret\" = \"3\"", "\"\" = 3", "\"*Secret\" = \"every\"", "\"\" = \"all\"",
    ])
    func invalidPatternIsRejectedWithoutTheTitle(line: String) {
        do {
            _ = try PaveConfig.parse("[apps.\"x\".titles]\n\(line)")
            Issue.record("accepted")
        } catch {
            #expect(error.line == 2 || error.line == 0)
            #expect(!error.message.contains("Secret"))
        }
    }

    @Test func patternsAreWrittenAndRemovedAsQuotedKeys() throws {
        let table = ConfigEdit.appTable("x") + ".titles"
        var text = "[apps.\"x\"]\nworkspace = 2\n"
        for pattern in ["*Work", "*a = b # c", "*\"quoted\"*", "back\\slash"] {
            text = ConfigEdit.set(table, pattern, to: "3", in: text)
            text = ConfigEdit.set(table, pattern, to: "4", in: text)  // replaced, not added
        }
        let rule = try PaveConfig.parse(text).0.rule(for: "x")
        #expect(rule.titles == ["*Work": 4, "*a = b # c": 4, "*\"quoted\"*": 4, "back\\slash": 4])
        for pattern in ["*a = b # c", "*\"quoted\"*", "back\\slash"] {
            text = ConfigEdit.remove(table, pattern, in: text)
        }
        #expect(try PaveConfig.parse(text).0.rule(for: "x").titles == ["*Work": 4])
        #expect(ConfigEdit.key("tile") == "tile")
        #expect(ConfigEdit.key("*Work") == "\"*Work\"")
    }

    @Test func aTrailingCommentStaysWhenAQuotedKeyChanges() {
        let text = "[apps.\"x\".titles]\n\"*a#b\" = 3 # mine\n"
        #expect(ConfigEdit.set("apps.\"x\".titles", "*a#b", to: "5", in: text).contains("\"*a#b\" = 5 # mine"))
    }

    @Test func deletingAnAppRuleTakesItsSubtables() throws {
        let text = """
            [apps."x"]
            workspace = 2

            [apps."x".titles]
            "*Work" = 3

            [apps."x".profiles]
            Perso = 1

            [apps."xy"]
            tile = false
            """
        let edited = ConfigEdit.removeTable(ConfigEdit.appTable("x"), in: text)
        #expect(!edited.contains("Work") && !edited.contains("Perso"))
        #expect(try PaveConfig.parse(edited).0.appRules.keys.sorted() == ["xy"])
    }
}
