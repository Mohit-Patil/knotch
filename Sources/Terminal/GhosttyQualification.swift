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
        if !condition { throw TerminalFailure.unavailable(name) }
    }
    static func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 8) async throws {
        let limit = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= limit { throw TerminalFailure.unavailable("Timed out waiting for real terminal output") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func send(_ text: String, to session: GhosttySession) {
        for scalar in text {
            let char = String(scalar)
            let code: UInt16 = char == "\r" ? 36 : 0
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
            send("printf 'RESIZE_GRID:'; stty size\r", to: terminal)
            try await waitFor { screen(terminal).contains("RESIZE_GRID:\(nextSize.rows) \(nextSize.columns)") }
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
            try check("ENG-10", terminal.status.contains("7") && terminal.surface != nil, "Observed nonzero exit retained terminal output: \(terminal.status)")
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
}
#endif
