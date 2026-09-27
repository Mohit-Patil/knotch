import AppKit

@MainActor
extension AppCoordinator {
    @objc func chooseTerminal() {
        showTerminal()
        let alert = NSAlert()
        alert.messageText = "New terminal"
        alert.informativeText = "Open another terminal for the current connection, a local home shell, or a saved server."
        alert.addButton(withTitle: "Current Connection")
        alert.addButton(withTitle: "Local Shell")
        alert.addButton(withTitle: "SSH Server…")
        alert.addButton(withTitle: "Cancel")
        switch runAppDialog({ alert.runModal() }) {
        case .alertFirstButtonReturn: newTab()
        case .alertSecondButtonReturn: openHome()
        case .alertThirdButtonReturn: connectServer()
        default: break
        }
    }

    @objc func reconnectSSH() {
        guard let target = store.session?.launchTarget, target.remoteConnection != nil else {
            showError(TerminalFailure.unavailable("Select an SSH tab to reconnect in a new tab."))
            return
        }
        // Preserve the old terminal's diagnostics and never replay its input.
        open(target: target)
    }

    @objc func connectServer() {
        showTerminal()
        do {
            var profiles = try sshConnections.load()
            var selectedID = profiles.first?.id
            while true {
                let alert = NSAlert()
                alert.messageText = "SSH connections"
                alert.informativeText = "Uses this Mac’s SSH configuration and keys. Password, passphrase, and host verification prompts appear in the terminal."
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
                picker.menu = NSMenu()
                for profile in profiles {
                    picker.menu?.addItem(NSMenuItem(title: "\(profile.name) — \(profile.identity)", action: nil, keyEquivalent: ""))
                }
                if let selectedID, let selected = profiles.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: selected) }
                if profiles.isEmpty { picker.addItem(withTitle: "No saved connections") }
                alert.accessoryView = picker
                alert.addButton(withTitle: "Connect").isEnabled = !profiles.isEmpty
                alert.addButton(withTitle: "Add…")
                alert.addButton(withTitle: "Edit…").isEnabled = !profiles.isEmpty
                alert.addButton(withTitle: "Delete").isEnabled = !profiles.isEmpty
                alert.addButton(withTitle: "Cancel")
                let result = runAppDialog { alert.runModal() }
                let index = picker.indexOfSelectedItem
                if profiles.indices.contains(index) { selectedID = profiles[index].id }
                switch result.rawValue {
                case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
                    guard profiles.indices.contains(index) else { return }
                    open(target: .ssh(profiles[index])); return
                case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                    if let profile = editSSHConnection(nil) {
                        profiles.append(profile); try sshConnections.save(profiles)
                        selectedID = profile.id
                    }
                case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                    if profiles.indices.contains(index), let profile = editSSHConnection(profiles[index]) {
                        profiles[index] = profile; try sshConnections.save(profiles)
                    }
                case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1:
                    if profiles.indices.contains(index) {
                        profiles.remove(at: index); try sshConnections.save(profiles)
                    }
                default: return
                }
            }
        } catch { showError(error) }
    }

    private func editSSHConnection(_ existing: SSHConnection?) -> SSHConnection? {
        let profile = existing ?? SSHConnection(name: "", host: "")
        let fields = [NSTextField(string: profile.name), NSTextField(string: profile.host),
                      NSTextField(string: profile.user), NSTextField(string: profile.port.map(String.init) ?? ""),
                      NSTextField(string: profile.remoteDirectory)]
        let shell = NSPopUpButton(frame: .zero)
        shell.addItems(withTitles: RemoteShell.allCases.map(\.rawValue))
        shell.selectItem(withTitle: profile.shell.rawValue)
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        let labels = ["Name", "SSH alias / hostname", "User (optional)", "Port (optional)", "Remote directory (optional)"]
        for (label, field) in zip(labels, fields) {
            field.placeholderString = label
            field.setAccessibilityLabel(label)
            form.addArrangedSubview(NSTextField(labelWithString: label))
            form.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        form.addArrangedSubview(NSTextField(labelWithString: "Remote shell"))
        form.addArrangedSubview(shell)
        shell.setAccessibilityLabel("Remote shell")
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 340)
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add SSH connection" : "Edit SSH connection"
        alert.informativeText = "Leave user and port blank to use SSH configuration. Shell and directory overrides require a Unix server with /bin/sh. No passwords or private keys are saved."
        alert.accessoryView = form
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields[0]
        while runAppDialog({ alert.runModal() }) == .alertFirstButtonReturn {
            do {
                var next = profile
                next.name = fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                next.host = fields[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                next.user = fields[2].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let port = fields[3].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !port.isEmpty, Int(port) == nil { throw SSHProfileError.invalid("Enter a numeric port between 1 and 65535.") }
                next.port = port.isEmpty ? nil : Int(port)
                next.remoteDirectory = fields[4].stringValue
                next.shell = RemoteShell.allCases[shell.indexOfSelectedItem]
                return try next.validated()
            } catch { showError(error) }
        }
        return nil
    }
}
