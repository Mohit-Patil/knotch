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
            _ = terminal.nativeView.binding("copy_to_clipboard")
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
            NSApp.activate()
            try await waitFor({ NSApp.isActive }, description: "foreground activation of focus fixture (launch this test with open -n)")
            sink.makeKeyAndOrderFront(nil)
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
            try check("Display placement", (overlay.panel.screen?.visibleFrame.contains(overlay.panel.frame) ?? false), "Actual panel frame \(overlay.panel.frame) is inside selected display usable geometry")
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
