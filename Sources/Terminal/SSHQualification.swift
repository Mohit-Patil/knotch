#if HARNESS_TESTS
import AppKit
import GhosttyKit

@MainActor
enum SSHQualification {
    static func run(coordinator: AppCoordinator) async {
        let env = ProcessInfo.processInfo.environment
        var success = false
        var detail = ""
        do {
            guard let portText = env["KNOTCH_SSH_FIXTURE_PORT"], let port = Int(portText),
                  let directory = env["KNOTCH_SSH_FIXTURE_DIRECTORY"] else {
                throw TerminalFailure.unavailable("SSH fixture environment is missing")
            }
            let profile = SSHConnection(name: "Local SSH fixture", host: "127.0.0.1", port: port,
                                        shell: .bash, remoteDirectory: directory)
            coordinator.open(target: .ssh(profile))
            guard let session = coordinator.store.session as? GhosttySession else {
                throw TerminalFailure.unavailable("SSH surface missing")
            }
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("Are you sure") })
            HarnessQualification.send("yes\r", to: session)
            try await Task.sleep(for: .milliseconds(600))
            HarnessQualification.send("printf '\\nSSH_READY:%s:%s\\n' \"$TERM\" \"$PWD\"; tty\r", to: session)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("SSH_READY:xterm-256color:" + directory)
                && HarnessQualification.screen(session).contains("/dev/ttys") })
            try HarnessQualification.check("SSH real PTY and remote directory", session.isRunning && session.status == "SSH process running", "Host verification, key authentication, TERM, remote directory, and tty confirmed")
            let before = ghostty_surface_size(session.surface!)
            coordinator.window?.setContentSize(NSSize(width: 780, height: 430))
            coordinator.window?.contentView?.layoutSubtreeIfNeeded()
            try await HarnessQualification.waitFor({
                session.nativeView.syncGeometry()
                return ghostty_surface_size(session.surface!).columns != before.columns
            })
            let size = ghostty_surface_size(session.surface!)
            HarnessQualification.send("for n in {1..20}; do printf 'REMOTE_SIZE:'; stty size; sleep 0.1; done; printf 'RESIZE_DONE\\n'\r", to: session)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("REMOTE_SIZE:\(size.rows) \(size.columns)") && HarnessQualification.screen(session).contains("\nRESIZE_DONE") }, description: "SSH resize to \(size.rows)x\(size.columns)")
            try HarnessQualification.check("SSH remote resize", true, "Remote stty matches resized Ghostty geometry")
            HarnessQualification.send("printf '\\033[?1049h\\033[2J\\033[HSSH_FULL_SCREEN\\n'; stty -echo -icanon min 1 time 0; dd bs=1 count=1 2>/dev/null; stty sane; printf '\\033[?1049lSSH_ALT_DONE\\n'\r", to: session)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("SSH_FULL_SCREEN") && !HarnessQualification.screen(session).contains("RESIZE_DONE") })
            HarnessQualification.send("q", to: session)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("SSH_ALT_DONE") && HarnessQualification.screen(session).contains("RESIZE_DONE") })
            try HarnessQualification.check("SSH alternate screen", true, "Remote raw input and full-screen transitions preserve previous output")
            coordinator.newTab()
            guard let second = coordinator.store.session as? GhosttySession, second.id != session.id else {
                throw TerminalFailure.unavailable("SSH duplicate missing")
            }
            try HarnessQualification.check("SSH duplicate target", second.launchTarget == session.launchTarget && session.isRunning, "New Tab retains profile and leaves original client running")
            try await Task.sleep(for: .milliseconds(700))
            HarnessQualification.send("printf '\\nSSH_SECOND_READY\\n'\r", to: second)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(second).contains("\nSSH_SECOND_READY") })
            second.setPresented(false)
            try await Task.sleep(for: .milliseconds(100))
            second.setPresented(true)
            try HarnessQualification.check("SSH hide retains process", second.isRunning, "Presentation changes retain SSH client")
            coordinator.store.closeAfterConfirmation(id: second.id)
            coordinator.selectSession(id: session.id)
            HarnessQualification.send("printf '\\nSSH_FIRST_ALIVE\\n'\r", to: session)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(session).contains("\nSSH_FIRST_ALIVE") })
            HarnessQualification.send("exit\r", to: session)
            try await HarnessQualification.waitFor({ !session.isRunning })
            try HarnessQualification.check("SSH close and exit", !session.isRunning && HarnessQualification.screen(session).contains("SSH_FIRST_ALIVE"), "Closing second tab preserves first; remote shell exit retains output")
            coordinator.reconnectSSH()
            guard let reconnected = coordinator.store.session as? GhosttySession, reconnected.id != session.id else {
                throw TerminalFailure.unavailable("SSH reconnect missing")
            }
            try await Task.sleep(for: .milliseconds(700))
            HarnessQualification.send("printf '\\nSSH_RECONNECTED\\n'\r", to: reconnected)
            try await HarnessQualification.waitFor({ HarnessQualification.screen(reconnected).contains("\nSSH_RECONNECTED") })
            try HarnessQualification.check("SSH reconnect", session.launchTarget == reconnected.launchTarget && !session.isRunning, "Manual reconnect starts a fresh tab and preserves ended diagnostics")
            success = true
        } catch { detail = error.localizedDescription }
        let report: [String: Any] = ["passed": success, "detail": detail, "results": HarnessQualification.records]
        if let output = env["KNOTCH_EVIDENCE"], let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output))
        }
        coordinator.store.closeAllAfterConfirmation()
        coordinator.quitting = true
        print(success ? "SSH native qualification passed" : "SSH native qualification failed: \(detail)")
        NSApp.terminate(nil)
    }
}
#endif
