#if HARNESS_TESTS
// Test-only real-engine qualification. Never compiled into the personal application.
import AppKit
import GhosttyKit

@MainActor
enum HarnessQualification {
    static var records: [[String: String]] = []
    static func check(_ name: String, _ condition: Bool, _ detail: String) throws {
        records.append(["test": name, "result": condition ? "PASSED" : "FAILED", "detail": detail])
        print("\(condition ? "PASS" : "FAIL") \(name): \(detail)")
        fflush(nil)
        if !condition { throw TerminalFailure.unavailable(name) }
    }
    static func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 8, description: String = "real terminal output") async throws {
        let limit = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= limit { throw TerminalFailure.unavailable("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func send(_ text: String, to session: GhosttySession) {
        for scalar in text {
            let char = String(scalar)
            let code: UInt16 = ["\r": 36, "\u{1b}": 53, "\t": 48, "\u{7f}": 51][char] ?? 0
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: session.view.window?.windowNumber ?? 0, context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
            session.nativeView.keyDown(with: event)
            session.nativeView.keyUp(with: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!)
        }
    }
    static func screen(_ session: GhosttySession) -> String {
        guard let surface = session.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return "" }
        defer { ghostty_surface_free_text(surface, &result) }
        guard let text = result.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(result.text_len)), as: UTF8.self)
    }
    static func run(coordinator: AppCoordinator) async {
        var session: GhosttySession?
        let output = ProcessInfo.processInfo.environment["KNOTCH_EVIDENCE"] ?? "/tmp/knotch-harness-results.json"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-qualification-\(UUID().uuidString)/Project space 日本語", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let runtime = coordinator.runtime else { throw TerminalFailure.unavailable("No runtime") }
            let terminal = try GhosttySession(runtime: runtime, directory: folder, testCommand: "/bin/zsh -f")
            session = terminal
            coordinator.attach(terminal)
            coordinator.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await waitFor { !screen(terminal).isEmpty }
            send("printf '\\033[2J\\033[H'; printf 'PTY_READY:%s\\n' $$; pwd; tty; stty size\r", to: terminal)
            try await waitFor { screen(terminal).contains("/dev/ttys") }
            let first = screen(terminal)
            let pid = ghostty_surface_foreground_pid(terminal.surface!)
            let tty = ghostty_surface_tty_name(terminal.surface!)
            let ttyName = tty.ptr.map { String(cString: $0) } ?? ""
            ghostty_string_free(tty)
            try check("G0-04/ENG-03", first.contains(folder.path) && pid > 0 && ttyName.hasPrefix("/dev/ttys"), "Real shell PID \(pid), tty \(ttyName); explicit cwd with spaces and Japanese characters matched")

            send("printf 'UNICODE_OK: café 日本語 🙂\\n'\r", to: terminal)
            try await waitFor { screen(terminal).contains("\nUNICODE_OK: café 日本語 🙂") }
            try check("G0-05 Unicode", true, "Native key/text path produced UTF-8 accented, CJK and emoji text in engine state")

            let initialSize = ghostty_surface_size(terminal.surface!)
            coordinator.window?.setContentSize(NSSize(width: 760, height: 420))
            coordinator.window?.contentView?.layoutSubtreeIfNeeded()
            try await waitFor {
                terminal.nativeView.syncGeometry()
                return ghostty_surface_size(terminal.surface!).columns != initialSize.columns
            }
            let nextSize = ghostty_surface_size(terminal.surface!)
            send("for n in {1..20}; do printf 'RESIZE_GRID:'; stty size; sleep 0.1; done; printf 'RESIZE_FINISHED\\n'\r", to: terminal)
            try await waitFor { screen(terminal).contains("RESIZE_GRID:\(nextSize.rows) \(nextSize.columns)") && screen(terminal).contains("\nRESIZE_FINISHED") }
            try check("G0-06/ENG-06", initialSize.columns != nextSize.columns && nextSize.rows > 0, "Child stty matches engine final \(nextSize.rows)x\(nextSize.columns); prior \(initialSize.rows)x\(initialSize.columns)")

            // An actual alternate-screen raw-input fixture: no terminal output fabricated by the app.
            send("printf '\\033[?1049h\\033[2J\\033[HFULL_SCREEN_FIXTURE\\n'; stty -echo -icanon min 1 time 0; dd bs=1 count=1 2>/dev/null; stty sane; printf '\\033[?1049lALT_DONE\\n'\r", to: terminal)
            try await waitFor { screen(terminal).contains("FULL_SCREEN_FIXTURE") && !screen(terminal).contains("RESIZE_GRID:") }
            send("q", to: terminal)
            try await waitFor { screen(terminal).contains("ALT_DONE") && screen(terminal).contains("RESIZE_GRID:") }
            try check("G0-05/ENG-05", true, "Real alternate screen entered, raw one-character input read, original screen restored")

            // Save and restore clipboard representations; fixture content is the only clipboard evidence.
            let savedClipboard = NSPasteboard.general.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
            defer {
                NSPasteboard.general.clearContents()
                let items = savedClipboard.map { pairs -> NSPasteboardItem in
                    let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item
                }
                NSPasteboard.general.writeObjects(items)
            }
            _ = terminal.nativeView.binding("select_all")
            let copyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: coordinator.window!.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            try check("Ghostty configured copy binding", terminal.nativeView.performKeyEquivalent(with: copyKey), "Native Command-C is resolved through Ghostty bindings")
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            try check("G0-05 selection/copy", copied.contains("UNICODE_OK:"), "Engine selection copied fixture text through native clipboard callback")
            send("read -r fixture; printf 'PASTE_RESULT:%s\\n' \"$fixture\"\r", to: terminal)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("literal café $ ; ` 日本語", forType: .string)
            _ = terminal.nativeView.binding("paste_from_clipboard")
            send("\r", to: terminal)
            try await waitFor { screen(terminal).contains("PASTE_RESULT:literal café $ ; ` 日本語") }
            try check("G0-05 paste", true, "Explicit engine paste preserved literal text; test separately pressed Return")

            let identity = terminal.surface
            send("for i in {1..65}; do printf 'BOUNDED_TICK:%s\\n' $i; sleep 1; done; printf 'COUNTER_DONE\\n'\r", to: terminal)
            try await waitFor { screen(terminal).contains("BOUNDED_TICK:1\n") }
            terminal.setFocused(false)
            terminal.setPresented(false)
            coordinator.window?.orderOut(nil)
            let start = Date()
            try await Task.sleep(for: .seconds(60))
            let hiddenText = screen(terminal)
            try check("ENG-07 hidden output", hiddenText.contains("BOUNDED_TICK:60") || hiddenText.contains("BOUNDED_TICK:61"), "Output drained during \(Int(Date().timeIntervalSince(start))) seconds hidden")
            coordinator.window?.makeKeyAndOrderFront(nil)
            terminal.setPresented(true)
            coordinator.window?.makeFirstResponder(terminal.view)
            terminal.setFocused(true)
            try await waitFor({ screen(terminal).contains("COUNTER_DONE") }, timeout: 10)
            try check("G0-06 retained identity", terminal.surface == identity && ghostty_surface_foreground_pid(terminal.surface!) == pid, "Same surface and shell PID \(pid) after hide/reveal")
            for _ in 0..<200 { terminal.setPresented(false); terminal.setPresented(true) }
            try check("200 surface occlusion cycles", terminal.surface == identity, "No surface recreation; not a performance or full overlay qualification")
            send("exit 7\r", to: terminal)
            try await waitFor { !terminal.isRunning }
            try check("ENG-10", terminal.status.contains("exit status unavailable") && terminal.surface != nil, "Controlled exit 7 retained output without a false success label; pinned macOS engine reports an unreliable numeric exit status")
            send("x", to: terminal)
            try check("Exit retention", terminal.surface == identity, "Later keypress does not free ended-session output")
        } catch {
            records.append(["test": "Harness completion", "result": "FAILED", "detail": error.localizedDescription])
            if let session { print("FIXTURE_SCREEN: \(screen(session))") }
        }
        session?.closeAfterConfirmation()
        let data = try? JSONSerialization.data(withJSONObject: ["engine": "982fe90d941e4b4aab4905ffcbcfdea60bd83343", "results": records] as [String: Any], options: [.prettyPrinted, .sortedKeys])
        if let data { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        coordinator.quitting = true
        coordinator.runtime?.shutdown()
        exit(records.contains { $0["result"] == "FAILED" } ? 1 : 0)
    }

    /// Keep the native tab fixture bounded and close only shells created by this test.
    static func qualifyTabs(coordinator: AppCoordinator, runtime: GhosttyRuntime, first: GhosttySession, directory: URL) async throws {
        var added: [GhosttySession] = []
        defer {
            for tab in added where tab.surface != nil {
                tab.view.removeFromSuperview()
                coordinator.store.closeAfterConfirmation(id: tab.id)
            }
            if first.surface != nil, coordinator.store.selectedID != first.id {
                coordinator.selectSession(id: first.id)
            }
        }

        let second = try GhosttySession(runtime: runtime, directory: directory, testCommand: "/bin/zsh -f")
        added.append(second)
        coordinator.store.adoptFixture(second)
        let third = try GhosttySession(runtime: runtime, directory: directory, testCommand: "/bin/zsh -f")
        added.append(third)
        coordinator.store.adoptFixture(third)
        try check("Tabs ordered store", coordinator.store.sessions.map(\.id) == [first.id, second.id, third.id] && coordinator.store.selectedID == third.id, "Three fixture sessions are ordered; adopting the last selected it")
        for tab in [second, third] {
            coordinator.selectSession(id: tab.id)
            try await waitFor({
                guard let surface = tab.surface else { return false }
                return !screen(tab).isEmpty && ghostty_surface_foreground_pid(surface) > 0
            }, description: "native shell in tab \(tab.id)")
        }

        let tabs = [first, second, third]
        let surfaces = tabs.compactMap(\.surface)
        let shellPIDs = surfaces.map(ghostty_surface_foreground_pid)
        let ttyNames = surfaces.map { surface -> String in
            let tty = ghostty_surface_tty_name(surface)
            defer { ghostty_string_free(tty) }
            return tty.ptr.map { String(cString: $0) } ?? ""
        }
        try check("Tabs independent PTYs", surfaces.count == 3 && Set(surfaces.map { UInt(bitPattern: $0) }).count == 3 && Set(shellPIDs).count == 3 && shellPIDs.allSatisfy { $0 > 0 } && Set(ttyNames).count == 3 && ttyNames.allSatisfy { $0.hasPrefix("/dev/ttys") }, "Native surfaces \(surfaces.map { UInt(bitPattern: $0) }); shell PIDs \(shellPIDs); PTYs \(ttyNames)")

        coordinator.selectSession(id: second.id)
        try await waitFor { coordinator.store.session?.id == second.id && second.view.superview === coordinator.container }
        send("printf '\\033]2;TAB_OSC_SAFE\\a'\r", to: second)
        try await waitFor { second.title.contains("TAB_OSC_SAFE") }
        try check("Tab OSC title", second.displayTitle.contains("TAB_OSC_SAFE"), "Shell OSC 2 changed the selected tab title")
        send("printf '\\033]2;TAB_BAD_\u{202E}RTL_\\a'\r", to: second)
        try await waitFor { second.title.contains("TAB_BAD_") }
        try check("Tab title sanitation", !second.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.isBidiControl }) && !second.displayTitle.unicodeScalars.contains(where: { $0.properties.isBidiControl }), "Untrusted OSC title omitted control and bidirectional formatting characters")
        second.customTitle = "Pinned tab name"
        send("printf '\\033]2;UPDATED_OSC_TITLE\\a'\r", to: second)
        try await waitFor { second.title.contains("UPDATED_OSC_TITLE") }
        try check("Custom tab rename", second.displayTitle == "Pinned tab name", "Custom name survived a later shell title change")
        second.customTitle = nil
        try check("Tab rename cleared", second.displayTitle.contains("UPDATED_OSC_TITLE"), "Clearing custom name exposes the latest shell title")
        second.customTitle = " Unsafe\tName\u{202E}\n"
        try check("Custom title sanitation", second.displayTitle == "Unsafe Name", "A custom rename removed control and bidirectional formatting characters")
        second.customTitle = nil
        let firstBeforeInput = screen(first)
        let thirdBeforeInput = screen(third)
        send("printf 'TAB_INPUT_ONLY:%s\\n' SECOND\r", to: second)
        try await waitFor { screen(second).contains("\nTAB_INPUT_ONLY:SECOND") }
        try check("Tab input isolation", coordinator.overlay?.panel.firstResponder === second.view && screen(first) == firstBeforeInput && screen(third) == thirdBeforeInput, "Selected tab owned the native responder and its input changed only its own surface")

        send("printf '\\033[2J\\033[H'; for i in {1..100}; do printf 'TAB_SCROLL:%03d\\n' $i; done\r", to: second)
        try await waitFor { screen(second).contains("TAB_SCROLL:100") }
        let bottom = screen(second)
        try check("Tab scrollback fixture", second.nativeView.binding("scroll_page_up"), "Ghostty accepted a native page-up scroll action")
        try await waitFor { screen(second) != bottom && screen(second).contains("TAB_SCROLL:") }
        let scrolled = screen(second)
        coordinator.selectSession(id: third.id)
        try await waitFor { coordinator.store.session?.id == third.id && third.view.superview === coordinator.container }
        coordinator.selectSession(id: second.id)
        try check("Tab retained scrollback", second.surface == surfaces[1] && screen(second) == scrolled, "Switching away and back retained the same surface and viewport scroll position")

        coordinator.selectSession(id: first.id)
        send("sleep 1; printf 'BACKGROUND_%s_DONE\\n' FIRST\r", to: first)
        coordinator.selectSession(id: third.id)
        send("sleep 1; printf 'BACKGROUND_%s_DONE\\n' THIRD\r", to: third)
        coordinator.selectSession(id: second.id)
        try await waitFor { screen(first).contains("\nBACKGROUND_FIRST_DONE") && screen(third).contains("\nBACKGROUND_THIRD_DONE") }
        try check("Inactive tabs keep output", tabs.allSatisfy(\.isRunning) && zip(tabs, surfaces).allSatisfy { $0.0.surface == $0.1 } && zip(tabs, shellPIDs).allSatisfy { ghostty_surface_foreground_pid($0.0.surface!) == $0.1 }, "Two inactive shells completed work while a third tab was selected; all original shells and surfaces remained")

        coordinator.selectSession(id: third.id)
        coordinator.store.closeAfterConfirmation(id: second.id)
        second.view.removeFromSuperview()
        try check("Close background tab", coordinator.store.selectedID == third.id && coordinator.store.sessions.map(\.id) == [first.id, third.id] && second.surface == nil && third.surface == surfaces[2], "Closing tab two by ID preserved the selected third shell")
        third.view.removeFromSuperview()
        coordinator.store.closeAfterConfirmation(id: third.id)
        try check("Close selected tab", coordinator.store.selectedID == first.id && coordinator.store.sessions.map(\.id) == [first.id], "Closing selected tab chose the remaining neighboring tab")
        coordinator.selectSession(id: first.id)
        try check("Selected neighbor presented", first.view.superview === coordinator.container && coordinator.store.session?.id == first.id && first.surface == surfaces[0], "Coordinator displayed the surviving shell without respawning it")
        first.view.removeFromSuperview()
        coordinator.store.closeAfterConfirmation(id: first.id)
        coordinator.showEmptyState()
        coordinator.overlay?.sessionChanged()
        try check("Close last tab", coordinator.store.sessions.isEmpty && coordinator.store.selectedID == nil && coordinator.store.session == nil && first.surface == nil, "Last fixture close left an empty store and safe empty presentation")
    }

    static func runSettings(coordinator: AppCoordinator) async {
        records = []
        let output = ProcessInfo.processInfo.environment["KNOTCH_EVIDENCE"] ?? "/tmp/knotch-settings-results.json"
        do {
            guard let runtime = coordinator.runtime, let overlay = coordinator.overlay else {
                throw TerminalFailure.unavailable("No overlay runtime")
            }
            overlay.fixtureControlsTracking = true
            try check("Shared empty panel",
                      overlay.layout?.panelFrame.size == CGSize(width: 720, height: 550),
                      "No-shell presentation uses the same size as Settings and Terminal")
            if let layout = overlay.layout, let display = overlay.panel.screen {
                let attached = abs(overlay.triggerFrame.maxY - display.frame.maxY) < 0.5
                    && abs(overlay.panel.frame.maxY - display.frame.maxY) < 0.5
                    && overlay.triggerFrame.intersects(overlay.panel.frame)
                    && overlay.panel.level == .statusBar
                let plainBand = layout.notchFrame != nil
                    || overlay.triggerFrame.minY >= display.visibleFrame.maxY - 0.5
                try check("Display-edge placement", attached && plainBand,
                          "Current display \(display.frame), visible \(display.visibleFrame), trigger \(overlay.triggerFrame), panel \(overlay.panel.frame); plain-display handle stays in the measured menu-bar band")
                let idle = overlay.idleTriggerAppearanceForFixture
                if layout.notchFrame != nil {
                    try check("Idle notch has no painted extension", idle.transparent && idle.labelHidden && !idle.shadow
                              && idle.receivesMouse && !overlay.panel.isVisible,
                              "The collapsed native trigger is clear, unlabelled, and shadow-free; the expanded panel is ordered out")
                } else {
                    try check("Plain display retains visible handle", !idle.transparent && !idle.labelHidden
                              && idle.receivesMouse && !idle.shadow,
                              "A display without a camera keeps its labelled handle")
                }
                // WindowServer applies a newly ordered window asynchronously.
                try? await waitFor({ overlay.idleTriggerHitForFixture }, timeout: 2,
                                   description: "idle trigger WindowServer registration")
                try check("Idle hover margin remains hittable", overlay.idleTriggerHitForFixture,
                          "WindowServer resolves a mouse hit in the narrow trigger margin to the actual trigger window")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-settings-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = try GhosttySession(runtime: runtime, directory: folder, testCommand: "/bin/zsh -f")
            coordinator.store.adoptFixture(session)
            coordinator.attach(session)
            overlay.activate()
            // This fixture checks Settings and session ownership. Settle the
            // unrelated spring when display-link callbacks are unavailable in
            // a headless CLI launch; the motion fixture tests animation itself.
            overlay.settlePresentationForFixture()
            try await waitFor({ !screen(session).isEmpty }, description: "settings fixture shell")
            if let layout = overlay.layout, let display = overlay.panel.screen {
                try check("Expanded display fit",
                          abs(overlay.panel.frame.maxY - display.frame.maxY) < 0.5
                            && layout.usableFrame.contains(overlay.panel.frame)
                            && abs(overlay.panel.frame.width - layout.panelFrame.width) < 0.5,
                          "Expanded native panel \(overlay.panel.frame) fits current screen placement \(layout.usableFrame) at its top edge")
            }
            overlay.setSystemDialogPresented(true)
            try check("System dialog layering", overlay.panel.level == .normal,
                      "Presenting a native picker lowers the notch panel below modal windows")
            overlay.setSystemDialogPresented(false)
            try check("System dialog level restored", overlay.panel.level == .statusBar,
                      "Closing or cancelling a native picker restores the edge overlay level")
            let surface = session.surface!
            let pid = ghostty_surface_foreground_pid(surface)
            let originalGrid = ghostty_surface_size(surface)
            overlay.setUserPanelSize(CGSize(width: 1000, height: 600))
            try await waitFor({ ghostty_surface_size(surface).columns != originalGrid.columns },
                              description: "terminal grid after panel resize")
            try check("Live terminal resize",
                      overlay.layout?.panelFrame.size == CGSize(width: 1000, height: 600)
                        && session.surface == surface
                        && ghostty_surface_foreground_pid(surface) == pid,
                      "Panel=\(String(describing: overlay.layout?.panelFrame.size)), surface=\(session.surface == surface), PID=\(pid)->\(ghostty_surface_foreground_pid(surface)); changing panel size must resize the real grid without replacing the shell")
            overlay.setUserPanelSize(nil)
            try check("Reset terminal size",
                      overlay.layout?.panelFrame.size != CGSize(width: 1000, height: 600),
                      "Reset returns to the current display's adaptive terminal dimensions")
            let beforeWindows = Set(NSApp.windows.map(\.windowNumber))
            send("sleep 1; printf 'SETTINGS_BACKGROUND_DONE\\n'\r", to: session)
            coordinator.showAccessSettings()
            try check("Shared Settings panel",
                      overlay.layout?.panelFrame.size == CGSize(width: 720, height: 550),
                      "In-panel preferences retain the same panel dimensions as Terminal")
            try check("Settings tab owns content", coordinator.statusLabel.stringValue == "Settings" && coordinator.store.session?.id == session.id && session.view.superview == nil && session.surface == surface && Set(NSApp.windows.map(\.windowNumber)) == beforeWindows, "Settings replaced the terminal in the same native panel without creating another window or freeing the shell")
            try await waitFor({ screen(session).contains("\nSETTINGS_BACKGROUND_DONE") }, description: "output while Settings is selected")
            coordinator.selectSession(id: session.id)
            try check("Settings return keeps shell", coordinator.statusLabel.stringValue != "Settings" && session.view.superview === coordinator.container && session.surface == surface && ghostty_surface_foreground_pid(surface) == pid && screen(session).contains("\nSETTINGS_BACKGROUND_DONE"), "Returning from Settings presented the same surface, shell PID, and background output")
            coordinator.showTools()
            overlay.settlePresentationForFixture()
            try check("Tools share the retained workspace",
                      coordinator.isToolsSelectedForFixture && session.view.superview == nil
                        && session.surface == surface && overlay.layout?.panelFrame.size == CGSize(width: 720, height: 550)
                        && coordinator.shelfHeightForFixture == 0,
                      "Tools use the same panel, hide the Clipboard shelf, and retain the real terminal surface")
            guard let tools = coordinator.toolsStoreForFixture else { throw TerminalFailure.unavailable("No tools store") }
            try check("Tools catalog", KnotchTool.allCases.count == 19 && Set(KnotchTool.allCases.map(\.id)).count == 19,
                      "Nineteen distinct utilities supplement Terminal and Clipboard")
            tools.selected = .notes
            coordinator.window?.layoutIfNeeded()
            try check("Utility navigation preserves shell", tools.isVisible && session.surface == surface
                      && ghostty_surface_foreground_pid(surface) == pid && !session.view.isDescendant(of: coordinator.container),
                      "Opening a local tool never creates or replaces a terminal")
            tools.context.beginDialog()
            tools.context.beginDialog()
            tools.context.endDialog()
            try check("Tools nested dialog hold", overlay.panel.level == .normal
                      && overlay.state.interactionLocks.contains("tools-dialog"),
                      "Nested native tool dialogs retain the overlay lock and lowered level until final dismissal")
            tools.context.endDialog()
            try check("Tools dialog release", overlay.panel.level == .statusBar
                      && !overlay.state.interactionLocks.contains("tools-dialog"),
                      "Final dismissal restores the window level and releases the interaction lock")
            let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            overlay.panel.beginSheet(sheet, completionHandler: { _ in })
            try await waitFor({ overlay.state.interactionLocks.contains("native-sheet") }, description: "native sheet hold")
            try check("Native sheet stays above tools", overlay.panel.level == .normal,
                      "Actual attached NSPanel sheet holds presentation and lowers the workspace")
            overlay.panel.endSheet(sheet)
            sheet.orderOut(nil)
            try await waitFor({ !overlay.state.interactionLocks.contains("native-sheet") }, description: "native sheet dismissal")
            try check("Native sheet releases visibility", overlay.panel.level == .statusBar,
                      "Dismissal releases the sheet hold and restores the workspace level")
            coordinator.hideTerminal()
            try check("Hidden tools suspend sensitive services", !tools.isVisible && tools.mirror.state == .idle,
                      "Hiding propagates service visibility and leaves the camera idle without requesting permission")
            coordinator.selectSession(id: session.id)
            try check("Tools return keeps shell", !coordinator.isToolsSelectedForFixture
                      && session.view.superview === coordinator.container && session.surface == surface
                      && ghostty_surface_foreground_pid(surface) == pid,
                      "Returning from Tools presents the same live Ghostty surface and shell PID")
            tools.shutdown()
            let notifications = coordinator.agentNotifications
            notifications.enabled = true
            notifications.onLeft = false
            notifications.clear()
            coordinator.hideTerminal()
            overlay.settlePresentationForFixture()
            let keyBeforeNotification = NSApp.keyWindow
            send("printf '\\033]777;notify;Claude fixture;Response complete\\007'\r", to: session)
            try await waitFor({ notifications.notices.count == 1 }, description: "real Ghostty OSC notification")
            try check("Agent notification from real PTY", notifications.notices.first?.sessionID == session.id
                      && notifications.notices.first?.message == "Response complete"
                      && notifications.panelForFixture?.isVisible == true,
                      "OSC 777 traversed the live PTY and pinned Ghostty callback to the native indicator")
            try check("Notification leaves focus and session intact", NSApp.keyWindow === keyBeforeNotification
                      && notifications.panelForFixture?.canBecomeKey == false
                      && overlay.state.presentation == .collapsed && session.surface == surface,
                      "Notification did not activate the overlay, move keyboard focus, or replace the shell")
            notifications.receive(sessionID: session.id, title: "Claude fixture", message: "Response complete")
            try check("Notification coalescing", notifications.notices.count == 1, "Repeated notification in one session does not stack windows")
            overlay.setSystemDialogPresented(true)
            try check("Notification yields to dialog", notifications.panelForFixture?.isVisible == false && notifications.notices.count == 1,
                      "Modal presentation hides the droplet without discarding its pending event")
            overlay.setSystemDialogPresented(false)
            notifications.openFirst()
            try check("Notification opens its terminal", coordinator.store.selectedID == session.id
                      && session.view.superview === coordinator.container && session.surface == surface
                      && notifications.notices.isEmpty, "Opening acknowledged the event and reattached its original terminal")
            try await Task.sleep(for: .milliseconds(1100)) // Respect the pinned engine's notification rate limit.
            coordinator.hideTerminal()
            send("printf '\\033]9;Codex fixture ready\\007'\r", to: session)
            try await waitFor({ notifications.notices.first?.message == "Codex fixture ready" }, description: "OSC 9 agent notification")
            try check("Codex OSC 9 notification", notifications.notices.first?.sessionID == session.id,
                      "Codex's documented OSC 9 format traverses the real engine and maps back to its terminal")
            notifications.dismissFirst()
            send("printf '\\007'; printf 'BELL_FIXTURE_DONE\\n'\r", to: session)
            try await waitFor({ screen(session).contains("\nBELL_FIXTURE_DONE") }, description: "bell fixture")
            try check("Bell is not agent completion", notifications.notices.isEmpty,
                      "Ordinary terminal bells are not interpreted as completed work")
            let display = NSRect(x: -1920, y: -100, width: 1920, height: 1080)
            let notch = NSRect(x: display.midX - 100, y: display.maxY - 38, width: 200, height: 38)
            let leftFrame = AgentNotificationController.frame(screen: display, notch: notch, menuHeight: 38, left: true)
            let rightFrame = AgentNotificationController.frame(screen: display, notch: notch, menuHeight: 38, left: false)
            try check("Notification side geometry", display.contains(leftFrame) && display.contains(rightFrame)
                      && leftFrame.maxX < notch.minX && rightFrame.minX > notch.maxX,
                      "Both sides sit outside the physical notch within a negative-origin external display")
            try check("Notification sanitizes terminal text", AgentNotificationController.clean("Hello\u{202E}\u{1b}World", limit: 80) == "HelloWorld",
                      "Untrusted terminal control and bidi characters are removed")
            let otherID = UUID()
            notifications.receive(sessionID: otherID, title: "Other", message: "Update")
            notifications.retainSessions([session.id])
            try check("Closed-tab notification removed", notifications.notices.isEmpty, "Removed terminals cannot leave stale actionable notices")
            notifications.enabled = false
            notifications.receive(sessionID: session.id, title: "Disabled", message: "Update")
            try check("Notification preference off", notifications.notices.isEmpty, "Disabled notifications do not create indicators")
            notifications.enabled = true
            notifications.clear()
            coordinator.selectSession(id: session.id)
            overlay.settlePresentationForFixture()
            let savedPasteboard = NSPasteboard.general.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
            defer {
                NSPasteboard.general.clearContents()
                let items = savedPasteboard.map { pairs in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                }
                NSPasteboard.general.writeObjects(items)
            }
            send("printf '\\033[2J\\033[H\\033]8;;https://example.com/knotch-test\\007Open test link\\033]8;;\\007\\n'\r", to: session)
            try await waitFor({ screen(session).contains("Open test link") }, description: "OSC 8 hyperlink fixture")
            let linkPosition = session.nativeView.convert(NSPoint(x: 25, y: session.nativeView.bounds.height - 10), to: nil)
            let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: linkPosition,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            guard let contextMenu = session.nativeView.menu(for: contextEvent),
                  let openLink = contextMenu.items.first(where: { $0.title == "Open in Browser" }),
                  let copyLink = contextMenu.items.first(where: { $0.title == "Copy Link" }) else {
                throw TerminalFailure.unavailable("Native hyperlink context actions missing")
            }
            try check("Native hyperlink context menu", openLink.representedObject as? String == "https://example.com/knotch-test",
                      "Right-click obtains the actual OSC 8 target through Ghostty, not the displayed label")
            _ = NSApp.sendAction(copyLink.action!, to: copyLink.target, from: copyLink)
            try check("Native Copy Link", NSPasteboard.general.string(forType: .string) == "https://example.com/knotch-test",
                      "The menu's real target/action writes the hyperlink destination to the system pasteboard")
            var openedURL: URL?
            session.nativeView.browserOpenerForFixture = { openedURL = $0; return true }
            _ = NSApp.sendAction(openLink.action!, to: openLink.target, from: openLink)
            try check("Native Open in Browser routing", openedURL?.absoluteString == "https://example.com/knotch-test",
                      "The real menu target/action reaches the injected OS-opening boundary with the right URL; no browser was launched in this fixture")
            session.nativeView.browserOpenerForFixture = nil
            _ = session.nativeView.binding("select_all")
            let copyItem = contextMenu.items.first { $0.title == "Copy" }!
            _ = NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem)
            try check("Native context Copy selection", NSPasteboard.general.string(forType: .string)?.contains("Open test link") == true,
                      "The context Copy action uses Ghostty's native selection and clipboard callback")
            send("printf '\\033]52;c;S05PVENIX0NMSVBCT0FSRF9GSVhUVVJF\\007'\r", to: session)
            try await waitFor({ NSPasteboard.general.string(forType: .string) == "KNOTCH_CLIPBOARD_FIXTURE" }, description: "agent OSC 52 clipboard write")
            try check("Agent OSC 52 copy", true, "A real programmatic clipboard escape reaches the macOS pasteboard with the engine's default allow policy")
            send("printf KNOTCH_PBCOPY_FIXTURE | /usr/bin/pbcopy\r", to: session)
            try await waitFor({ NSPasteboard.general.string(forType: .string) == "KNOTCH_PBCOPY_FIXTURE" }, description: "shell pbcopy")
            try check("Shell pbcopy", true, "A subprocess in the embedded PTY can write the macOS pasteboard")
            try check("Browser URL bounds", GhosttyNativeView.browserURL("javascript:alert(1)") == nil
                      && GhosttyNativeView.browserURL("file:///tmp/test") == nil
                      && GhosttyNativeView.browserURL("https://") == nil
                      && GhosttyNativeView.browserURL("http://localhost:3000") != nil,
                      "HTTP(S) links including localhost are supported; script, file and incomplete URLs are rejected")
            coordinator.overlay?.hide(restoreFocus: false)
            session.view.removeFromSuperview()
            coordinator.store.closeAfterConfirmation(id: session.id)
            try await waitFor({ kill(pid_t(pid), 0) != 0 }, description: "fixture shell close")
        } catch {
            records.append(["test": "Settings completion", "result": "FAILED", "detail": error.localizedDescription])
        }
        let data = try? JSONSerialization.data(withJSONObject: ["engine": "982fe90d941e4b4aab4905ffcbcfdea60bd83343", "results": records] as [String: Any], options: [.prettyPrinted, .sortedKeys])
        if let data { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        coordinator.store.closeAllAfterConfirmation()
        coordinator.quitting = true
        coordinator.shortcut?.shutdown()
        coordinator.runtime?.shutdown()
        exit(records.contains { $0["result"] == "FAILED" } ? 1 : 0)
    }

    static func runOverlay(coordinator: AppCoordinator) async {
        records = []
        let output = ProcessInfo.processInfo.environment["KNOTCH_EVIDENCE"] ?? "/tmp/knotch-overlay-results.json"
        do {
            guard let runtime = coordinator.runtime, let overlay = coordinator.overlay else { throw TerminalFailure.unavailable("No overlay runtime") }
            overlay.fixtureControlsTracking = true
            overlay.reduceMotionForFixture = false
            try check("Collapsed launch", overlay.state.presentation == .collapsed && !overlay.panel.isVisible, "Launch exposes only the notch trigger, without activating the terminal")
            if let layout = overlay.layout, let notch = layout.notchFrame, let screen = overlay.panel.screen {
                try check("Notch attachment", overlay.triggerFrame == layout.triggerFrame && overlay.triggerFrame.maxY == screen.frame.maxY && overlay.triggerFrame.contains(notch) && overlay.triggerFrame.intersects(overlay.panel.frame), "Actual cap \(overlay.triggerFrame) covers reported cutout \(notch) and overlaps terminal body \(overlay.panel.frame); no detached pill")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-overlay-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = try GhosttySession(runtime: runtime, directory: folder, testCommand: "/bin/zsh -f")
            coordinator.store.adoptFixture(session)
            coordinator.attach(session)
            overlay.activate()
            try await waitFor { !screen(session).isEmpty }
            send("printf '\\033[2J\\033[HOVERLAY_READY\\n'; printf 'SHELL:%s\\n' $$\r", to: session)
            try await waitFor { screen(session).contains("\nSHELL:") }
            send("printf 'COLOR_ENV:%s:%s:%s\\n' \"${NO_COLOR-unset}\" \"$COLORTERM\" \"$TERM\"\r", to: session)
            try await waitFor { screen(session).contains("COLOR_ENV:unset:truecolor:xterm-ghostty") }
            try check("Color-capable child environment", true, "Real PTY child has no inherited NO_COLOR and advertises truecolor with xterm-ghostty")
            let surface = session.surface
            let pid = ghostty_surface_foreground_pid(surface!)
            try await waitFor { !overlay.isAnimating }
            let restingGrid = ghostty_surface_size(surface!)
            let restingView = session.view.frame.size
            overlay.hide(restoreFocus: false)
            try await waitFor { !overlay.panel.isVisible }
            overlay.activate()
            try await Task.sleep(for: .milliseconds(70))
            let movingGrid = ghostty_surface_size(surface!)
            try check("Spring clip keeps terminal grid", overlay.isAnimating && overlay.panel.frame.height < overlay.layout!.panelFrame.height && session.view.frame.size == restingView && movingGrid.columns == restingGrid.columns && movingGrid.rows == restingGrid.rows, "Actual native panel expands through intermediate geometry while Ghostty rows, columns and view size remain fixed")
            overlay.hide(restoreFocus: false)
            try await Task.sleep(for: .milliseconds(60))
            overlay.activate()
            try await waitFor { !overlay.isAnimating }
            try check("Interrupted spring reopen", overlay.panel.isVisible && overlay.state.presentation == .interactive && session.surface == surface, "Close interrupted by reopen settles visible with same terminal surface")
            overlay.hide(restoreFocus: false)
            overlay.send(.screenLocked)
            try check("Lock bypasses motion", !overlay.panel.isVisible && !overlay.isAnimating, "Supplied lock event hides immediately without an animated privacy delay")
            overlay.reduceMotionForFixture = true
            overlay.activate()
            try check("Reduce Motion fixed geometry", overlay.panel.frame.size == overlay.layout!.panelFrame.size && abs(overlay.panel.frame.midX - overlay.layout!.panelFrame.midX) <= 0.5, "Fixture Reduce Motion override uses full resting geometry (allowing native half-point origin rounding) and a short opacity fade")
            try await waitFor { !overlay.isAnimating }
            overlay.hide(restoreFocus: false)
            try await waitFor { !overlay.panel.isVisible }
            overlay.reduceMotionForFixture = false

            // A real native key window. This qualifies native panel nonactivation,
            // not a physical mouse crossing or a different application's responder.
            let sink = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 480, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            sink.title = "Knotch focus qualification"
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
            sink.contentView = editor
            sink.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await waitFor({ NSApp.isActive && sink.isKeyWindow }, description: "foreground activation of visible focus fixture")
            sink.makeFirstResponder(editor)
            try await waitFor({ sink.isKeyWindow }, description: "native editor key window")
            overlay.send(.pointerEnteredTrigger)
            try await Task.sleep(for: .milliseconds(50))
            overlay.send(.pointerExitedTrigger)
            try await Task.sleep(for: .milliseconds(180))
            try check("UX-01 native controller", !overlay.panel.isVisible && sink.isKeyWindow, "Below-dwell tracking events: panel visible=\(overlay.panel.isVisible), sink key=\(sink.isKeyWindow), state=\(overlay.state.presentation)")
            overlay.send(.pointerEnteredTrigger)
            try await waitFor { overlay.state.presentation == .preview }
            try check("UX-02 native controller", overlay.panel.isVisible && !overlay.panel.isKeyWindow && sink.isKeyWindow, "Dwell revealed actual NSPanel without changing the existing native key window; tracking events supplied by test")
            let textBefore = screen(session)
            editor.insertText("FOCUS_PROBE", replacementRange: NSRange(location: NSNotFound, length: 0))
            try check("UX-02 responder ownership", sink.firstResponder === editor && screen(session) == textBefore && editor.string == "FOCUS_PROBE", "Native editor kept its responder; terminal input/state unchanged")
            overlay.send(.pointerExitedTrigger)
            try await Task.sleep(for: .milliseconds(100))
            overlay.send(.pointerEnteredPanel)
            try await Task.sleep(for: .milliseconds(400))
            try check("UX-06/UX-07 controller", overlay.state.presentation == .preview, "Reentry cancelled exit grace; trigger/panel use adjacent geometry")
            overlay.activate()
            try await waitFor { overlay.panel.isKeyWindow }
            try check("UX-03 activation", overlay.state.presentation == .interactive && overlay.panel.firstResponder === session.view, "Deliberate controller activation made actual panel and terminal key")
            send("printf 'TYPING_HOLDS\\n'\r", to: session)
            overlay.send(.pointerExitedPanel)
            try await Task.sleep(for: .milliseconds(400))
            try check("Typing postpones minimise", overlay.panel.isVisible && overlay.panel.isKeyWindow, "Real terminal input postponed auto-collapse after pointer exit")
            try await waitFor({ !overlay.panel.isVisible }, timeout: 3, description: "idle pointer-exit minimise")
            try check("Interactive auto-minimise", session.surface == surface && ghostty_surface_foreground_pid(surface!) == pid, "After typing grace expired, panel collapsed with same shell and surface")
            overlay.send(.pointerEnteredTrigger)
            try await waitFor { overlay.state.presentation == .preview }
            overlay.send(.pointerExitedTrigger)
            overlay.send(.pointerExitedPanel)
            try await waitFor({ !overlay.panel.isVisible }, description: "hover preview auto-minimise")
            try check("Preview auto-minimise", true, "Leaving a hover preview collapsed the native panel after exit grace")
            overlay.send(.pointerEnteredPanel)
            overlay.activate()
            overlay.setInteractionLock("selection-fixture", true)
            overlay.send(.pointerExitedPanel)
            try await Task.sleep(for: .milliseconds(1700))
            try check("Selection prevents minimise", overlay.panel.isVisible, "An active interaction lock held the panel beyond typing grace")
            // Opening the chosen project reactivates while its picker lock is still held.
            overlay.activate()
            overlay.setInteractionLock("selection-fixture", false)
            try await waitFor({ !overlay.panel.isVisible }, description: "minimise after interaction ends")
            overlay.activate()
            send("stty -echo -icanon min 1 time 0; printf 'ESC_READY\\n'; dd bs=1 count=1 2>/dev/null | od -An -tu1; stty sane; printf 'ESC_DONE\\n'\r", to: session)
            try await waitFor { screen(session).contains("\nESC_READY") }
            send("\u{1b}", to: session)
            try await waitFor { screen(session).contains("\nESC_DONE") }
            try check("UX-08", screen(session).contains("27") && overlay.state.presentation == .interactive, "Escape reached the real raw-input program as byte 27; panel stayed interactive")
            overlay.setInteractionLock("fixture-modal", true)
            sink.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(450))
            try check("UX-09 native lock", overlay.panel.isVisible && !overlay.panel.isKeyWindow, "A presentation lock kept the actual panel visible through focus loss")
            overlay.setInteractionLock("fixture-modal", false)
            try await waitFor({ !overlay.panel.isVisible }, timeout: 3, description: "dialog unlock with pointer outside")
            try check("Dialog unlock settles unfocused preview", overlay.state.presentation == .collapsed,
                          "The last dialog lock releases a focus-lost preview even without a new pointer exit")

            overlay.activate()
            overlay.send(.pointerEnteredPanel)
            overlay.send(.pointerExitedPanel)
            overlay.send(.displayChanged(overlay.state.targetDisplayID))
            try await waitFor({ !overlay.panel.isVisible }, description: "display change retains exit")
            try check("Display change retains minimise", overlay.state.presentation == .collapsed,
                          "A supplied display-change event does not strand the pending native panel collapse")

            overlay.hide(restoreFocus: false)
            overlay.send(.pointerEnteredTrigger)
            overlay.send(.displayChanged(overlay.state.targetDisplayID))
            overlay.send(.pointerEnteredTrigger)
            try await waitFor { overlay.state.presentation == .preview }
            try check("Hover recovers after display change", overlay.panel.isVisible && !overlay.state.ownsFocus,
                          "Fresh pointer containment after a supplied display change starts a new focus-free dwell")

            overlay.hide(restoreFocus: false)
            overlay.activate()
            try await waitFor { overlay.panel.isKeyWindow && !overlay.isAnimating }
            let searchField = NSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
            overlay.panel.contentView?.addSubview(searchField)
            overlay.panel.makeFirstResponder(searchField)
            overlay.send(.pointerEnteredPanel)
            overlay.send(.pointerExitedPanel)
            let fieldKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: overlay.panel.windowNumber, context: nil,
                                           characters: "x", charactersIgnoringModifiers: "x",
                                           isARepeat: false, keyCode: 7)!
            overlay.panel.sendEvent(fieldKey)
            try await Task.sleep(for: .milliseconds(450))
            try check("Text controls retain typing grace", overlay.state.presentation == .interactive
                          && searchField.stringValue == "x",
                          "A key delivered to a native text field postpones pointer-exit collapse without redirecting input into Ghostty")
            overlay.panel.makeFirstResponder(session.view)
            searchField.removeFromSuperview()
            try await waitFor({ !overlay.panel.isVisible }, timeout: 3, description: "text-control typing grace ends")

            overlay.hide(restoreFocus: false)
            let outside = NSPoint(x: overlay.layout!.panelFrame.minX - 30,
                                  y: overlay.layout!.panelFrame.minY - 30)
            overlay.pointerLocationForFixture = outside
            overlay.externalDragChanged(true)
            overlay.externalDragChanged(false)
            // Moving from the trigger to the panel must cancel the old exit.
            try await Task.sleep(for: .milliseconds(180))
            overlay.externalDragChanged(true)
            try await Task.sleep(for: .milliseconds(400))
            try check("External drag handoff retains lock", overlay.panel.isVisible
                          && overlay.state.interactionLocks.contains("external-drag"),
                          "Re-entering another destination invalidates the previous delayed drag unlock")
            overlay.externalDragChanged(false)
            try await waitFor({ !overlay.panel.isVisible }, description: "cancelled external drag outside")
            try check("Cancelled drag minimises outside", overlay.state.presentation == .collapsed
                          && !overlay.state.interactionLocks.contains("external-drag"),
                          "A supplied outside drag endpoint collapses the panel without ordinary mouse-exit events")

            overlay.pointerLocationForFixture = NSPoint(x: overlay.layout!.panelFrame.midX,
                                                        y: overlay.layout!.panelFrame.midY)
            overlay.externalDragChanged(true)
            try await waitFor { !overlay.isAnimating }
            overlay.externalDragChanged(false)
            try await Task.sleep(for: .milliseconds(800))
            try check("Drop inside remains open", overlay.state.presentation == .interactive
                          && overlay.state.pointerInPanel && overlay.panel.isVisible
                          && !overlay.state.interactionLocks.contains("external-drag"),
                          "A supplied inside endpoint keeps the panel open after its drag lock is released")
            overlay.hide(restoreFocus: false)
            overlay.pointerLocationForFixture = nil
            try check("Visibility recovery retains session", session.surface == surface
                          && ghostty_surface_foreground_pid(surface!) == pid,
                          "Dialog, display and drag recovery preserve the original Ghostty surface and shell")
            overlay.hide(restoreFocus: false)
            for _ in 0..<200 {
                overlay.activate()
                overlay.hide(restoreFocus: false)
            }
            overlay.activate()
            try check("Alpha retained session", session.surface == surface && ghostty_surface_foreground_pid(surface!) == pid, "200 actual panel reveal/hide calls kept the same surface and PID \(pid); not a latency/soak measurement")
            overlay.setHoverEnabled(false)
            overlay.hide(restoreFocus: false)
            try await waitFor { !overlay.panel.isVisible }
            overlay.send(.pointerEnteredTrigger)
            try await Task.sleep(for: .milliseconds(240))
            try check("UX-14 controller", !overlay.panel.isVisible, "Disabled hover ignored dwell; explicit activation remains available")
            overlay.activate()
            try await waitFor { !overlay.isAnimating }
            if let notch = overlay.layout?.notchFrame {
                let titleFrame = overlay.panel.convertToScreen(coordinator.statusLabel.convert(coordinator.statusLabel.bounds, to: nil))
                let terminalFrame = overlay.panel.convertToScreen(session.view.convert(session.view.bounds, to: nil))
                try check("Camera-safe content", !titleFrame.intersects(notch) && terminalFrame.maxY <= notch.minY, "Native project title stays beside the cutout; terminal content starts below the camera")
                try check("Expanded screen-edge alignment", overlay.panel.frame.maxY == overlay.panel.screen!.frame.maxY && overlay.panel.frame.contains(notch) && overlay.panel.level == .statusBar, "Expanded native panel reaches the screen top and contains the measured camera cutout; header uses its side wings")
            }
            try check("Display placement", (overlay.layout?.usableFrame.contains(overlay.panel.frame) ?? false), "Actual panel frame \(overlay.panel.frame) is inside selected display placement bounds (including the notch header band)")
            send("sleep 1; printf 'SETTINGS_BACKGROUND_DONE\\n'\r", to: session)
            coordinator.showAccessSettings()
            try check("Settings in notch", coordinator.statusLabel.stringValue == "Settings" && coordinator.store.session?.id == session.id && session.view.superview == nil && session.surface == surface, "Settings replaced the terminal inside the existing panel while its session and shell remained owned")
            try await waitFor { screen(session).contains("\nSETTINGS_BACKGROUND_DONE") }
            coordinator.selectSession(id: session.id)
            try check("Settings return retains terminal", coordinator.statusLabel.stringValue != "Settings" && session.view.superview === coordinator.container && session.surface == surface && ghostty_surface_foreground_pid(surface!) == pid, "Returning from Settings showed the same surface, shell PID, and background output")
            try await qualifyTabs(coordinator: coordinator, runtime: runtime, first: session, directory: folder)
            sink.orderOut(nil)
            session.view.removeFromSuperview()
            coordinator.store.closeAfterConfirmation()
            try await waitFor { kill(pid_t(pid), 0) != 0 }
            try check("Confirmed close lifecycle", true, "Explicitly freed only the fixture surface; its tracked shell PID ended")
        } catch {
            records.append(["test": "Overlay completion", "result": "FAILED", "detail": error.localizedDescription])
            print("OVERLAY_FAILURE: \(error.localizedDescription)")
            if let overlay = coordinator.overlay { print("OVERLAY_STATE: \(overlay.state)") }
        }
        let data = try? JSONSerialization.data(withJSONObject: ["engine": "982fe90d941e4b4aab4905ffcbcfdea60bd83343", "results": records] as [String: Any], options: [.prettyPrinted, .sortedKeys])
        if let data { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        coordinator.store.closeAfterConfirmation()
        coordinator.quitting = true
        coordinator.shortcut?.shutdown()
        coordinator.runtime?.shutdown()
        exit(records.contains { $0["result"] == "FAILED" } ? 1 : 0)
    }
}
#endif
