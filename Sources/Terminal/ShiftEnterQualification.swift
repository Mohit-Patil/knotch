#if HARNESS_TESTS
import AppKit

extension HarnessQualification {
    /// Read actual PTY bytes after the normal AppKit key-down/key-up path.
    static func qualifyShiftEnter(runtime: GhosttyRuntime, session: GhosttySession) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = directory.appendingPathComponent("keys.py")
        try #"""
        import os, select, sys, termios, tty
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
        mode = int(sys.argv[1])
        protocols = ['\x1b[>4;0m\x1b[=0u', '\x1b[>4;2m', '\x1b[=1u']
        data = b''
        try:
            tty.setraw(fd)
            print(protocols[mode] + '\x1b[2J\x1b[HKEYS_READY', flush=True)
            if not select.select([fd], [], [], 5)[0]:
                raise TimeoutError('No key event received')
            data = os.read(fd, 4096)
            while select.select([fd], [], [], 0.2)[0]:
                data += os.read(fd, 4096)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            print('\x1b[>4;0m\x1b[=0u\r\nKEYS_HEX:' + data.hex(), flush=True)
        """#.write(to: probe, atomically: true, encoding: .utf8)

        func key(_ code: UInt16 = 36, shift: Bool = true, repeatKey: Bool = false) {
            let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
            let text = code == 76 ? "\u{3}" : "\r"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: session.view.window?.windowNumber ?? 0,
                                            context: nil, characters: text, charactersIgnoringModifiers: text,
                                            isARepeat: type == .keyDown && repeatKey, keyCode: code)!
                if type == .keyDown { session.nativeView.keyDown(with: event) }
                else { session.nativeView.keyUp(with: event) }
            }
        }

        func capture(_ mode: Int, expected: String, name: String, input: () -> Void) async throws {
            send("/usr/bin/python3 '\(probe.path)' \(mode)\r", to: session)
            try await waitFor({ screen(session).contains("KEYS_READY") && !screen(session).contains("KEYS_HEX:") },
                              description: "raw keyboard receiver")
            input()
            try await waitFor({ screen(session).contains("KEYS_HEX:") }, description: "captured PTY key bytes")
            let line = screen(session).components(separatedBy: "\n").first { $0.hasPrefix("KEYS_HEX:") }
            try check(name, line?.trimmingCharacters(in: .whitespacesAndNewlines) == "KEYS_HEX:\(expected)",
                      "Expected \(expected); received \(line ?? "no result"). Includes key releases.")
        }

        for (mode, name) in ["legacy", "modifyOtherKeys", "Kitty"].enumerated() {
            try await capture(mode, expected: "0a0a0a0d", name: "Shift+Enter newline: \(name)") {
                key()
                key(76)
                key(repeatKey: true)
                key(shift: false)
            }
        }

        let config = directory.appendingPathComponent("config")
        try "keybind = shift+enter=text:OVERRIDE\n".write(to: config, atomically: true, encoding: .utf8)
        try runtime.reloadConfigurationForFixture(file: config)
        try await capture(0, expected: "4f56455252494445", name: "User can override Shift+Enter") { key() }
        // Existing configuration files need not repeat newly shipped defaults.
        try "# Existing personal configuration\n".write(to: config, atomically: true, encoding: .utf8)
        try runtime.reloadConfigurationForFixture(file: config)
        try await capture(0, expected: "0a0d", name: "Reload retains default newline binding") {
            key()
            key(shift: false)
        }
    }
}
#endif
