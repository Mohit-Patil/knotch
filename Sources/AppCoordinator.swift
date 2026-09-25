import AppKit

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var runtime: GhosttyRuntime?
    let store = SessionStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    let statusLabel = NSTextField(labelWithString: "Open a terminal in a project")
    let container = NSView()
    var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        do { runtime = try GhosttyRuntime() }
        catch {
            #if HARNESS_TESTS
            if CommandLine.arguments.contains("--self-test") {
                FileHandle.standardError.write(Data("ENGINE_ERROR: \(error.localizedDescription)\n".utf8))
                exit(2)
            }
            #endif
            showError(error)
            return
        }
        makeHarnessWindow()
        #if HARNESS_TESTS
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in await HarnessQualification.run(coordinator: self) }
            return
        }
        #endif
        if let index = CommandLine.arguments.firstIndex(of: "--directory"), index + 1 < CommandLine.arguments.count {
            open(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Terminal", action: #selector(showTerminal), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "Open Project…", action: #selector(chooseProject), keyEquivalent: "o").target = self
        appMenu.addItem(withTitle: "Open Home Shell", action: #selector(openHome), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Hide Terminal", action: #selector(hideTerminal), keyEquivalent: "h").target = self
        appMenu.addItem(withTitle: "Close Session…", action: #selector(closeSession), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Knotch…", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = ">_"
        statusItem?.button?.setAccessibilityLabel("Knotch terminal")
        statusItem?.menu = appMenu.copy() as? NSMenu
    }

    func makeHarnessWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Knotch · Ghostty engine harness"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        window.delegate = self
        window.center()
        window.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        for (title, action) in [("Open Project…", #selector(chooseProject)), ("Home Shell", #selector(openHome)), ("Hide", #selector(hideTerminal)), ("Close…", #selector(closeSession))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(title)
            toolbar.addArrangedSubview(button)
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        toolbar.addArrangedSubview(statusLabel)
        for view in [toolbar, container] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        self.window = window
    }

    func attach(_ session: any TerminalSession) {
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        session.onStatusChange = { [weak self, weak session] in self?.statusLabel.stringValue = session?.status ?? "No session" }
        session.onCloseRequested = { [weak self] in self?.closeSession() }
        session.onActivate = { [weak self] in self?.showTerminal() }
        statusLabel.stringValue = session.status
        window?.layoutIfNeeded()
        session.setPresented(true)
        window?.makeFirstResponder(session.view)
        session.setFocused(true)
    }

    func open(directory: URL) {
        guard let runtime else { return }
        do {
            try store.open(runtime: runtime, directory: directory)
            if let session = store.session { attach(session) }
            showTerminal()
        } catch { showError(error) }
    }

    @objc func chooseProject() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Open Terminal"
        if picker.runModal() == .OK, let url = picker.url { open(directory: url) }
    }
    @objc func openHome() { open(directory: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func showTerminal() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let session = store.session {
            session.setPresented(true)
            window?.makeFirstResponder(session.view)
            session.setFocused(true)
        }
    }
    @objc func hideTerminal() {
        store.session?.setFocused(false)
        store.session?.setPresented(false)
        window?.orderOut(nil)
    }
    @objc func closeSession() {
        guard let session = store.session else { return }
        if session.isRunning {
            let alert = NSAlert()
            alert.messageText = "End this terminal session?"
            alert.informativeText = "The shell and its running tools will end. Hide keeps them running."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "End Session")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        session.view.removeFromSuperview()
        store.closeAfterConfirmation()
        statusLabel.stringValue = "Session closed · Open a project to start another"
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        if store.session?.isRunning == true {
            let alert = NSAlert()
            alert.messageText = "Quit and end the terminal session?"
            alert.informativeText = "Sessions do not survive app exit. Hiding keeps your shell and tools running."
            alert.addButton(withTitle: "Keep App Running")
            alert.addButton(withTitle: "Hide Instead")
            alert.addButton(withTitle: "Quit and End Session")
            switch alert.runModal() {
            case .alertThirdButtonReturn: break
            case .alertSecondButtonReturn: hideTerminal(); return .terminateCancel
            default: return .terminateCancel
            }
        }
        store.closeAfterConfirmation()
        runtime?.shutdown()
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideTerminal(); return false }
    func windowDidBecomeKey(_ notification: Notification) { store.session?.setFocused(true) }
    func windowDidResignKey(_ notification: Notification) { store.session?.setFocused(false) }
    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
