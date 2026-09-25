import AppKit
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var runtime: GhosttyRuntime?
    let store = SessionStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var overlay: OverlayController?
    var shortcut: ShortcutController?
    var emptyView: NSView?
    let statusLabel = NSTextField(labelWithString: "Open a terminal in a project")
    let container = NSView()
    var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let harness = CommandLine.arguments.contains("--harness") || CommandLine.arguments.contains("--self-test")
        var qualification = false
        #if HARNESS_TESTS
        qualification = CommandLine.arguments.contains("--overlay-self-test")
        #endif
        // The focus fixture also owns an ordinary editor window; production remains accessory.
        NSApp.setActivationPolicy(harness || qualification ? .regular : .accessory)
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
        if harness {
            makeHarnessWindow()
        } else {
            let controller = OverlayController(content: makeContent(), sessionProvider: { [weak self] in self?.store.session })
            overlay = controller
            window = controller.panel
            controller.onPresentationChange = { [weak self] _ in self?.updateStatus() }
            let shortcut = ShortcutController()
            self.shortcut = shortcut
            shortcut.onToggle = { [weak self] in
                guard let self, let overlay = self.overlay else { return }
                if overlay.state.presentation == .interactive && overlay.panel.isKeyWindow { self.hideTerminal() }
                else { self.showTerminal() }
            }
            if let error = shortcut.restoreConfirmedShortcut() {
                showError(TerminalFailure.unavailable(error))
            }
            let hover = UserDefaults.standard.object(forKey: "access.hover.v1") as? Bool ?? true
            controller.setHoverEnabled(hover)
            controller.activate()
        }
        #if HARNESS_TESTS
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in await HarnessQualification.run(coordinator: self) }
            return
        }
        if CommandLine.arguments.contains("--overlay-self-test") {
            Task { @MainActor in await HarnessQualification.runOverlay(coordinator: self) }
            return
        }
        #endif
        if let index = CommandLine.arguments.firstIndex(of: "--directory"), index + 1 < CommandLine.arguments.count {
            open(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        if harness { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
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
        appMenu.addItem(withTitle: "Access & Shortcut…", action: #selector(showAccessSettings), keyEquivalent: ",").target = self
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
        window.contentView = makeContent()
        self.window = window
    }

    func makeContent() -> NSView {
        let root = NSView()
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        for (title, action) in [("Open Project…", #selector(chooseProject)), ("Home Shell", #selector(openHome)), ("Hide", #selector(hideTerminal)), ("Close…", #selector(closeSession)), ("Shortcut…", #selector(showAccessSettings))] {
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
        showEmptyState()
        return root
    }

    func showEmptyState() {
        let empty = NSHostingView(rootView: VStack(spacing: 16) {
            Image(systemName: "terminal").font(.system(size: 34, weight: .light))
            Text("A terminal within reach").font(.title2.weight(.semibold))
            Text("Open a project or a home shell above.\nRun your installed coding tools here.\nHover to inspect; click or use a shortcut to type.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Hiding keeps your session running. Quitting ends it.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30))
        empty.frame = container.bounds
        empty.autoresizingMask = [.width, .height]
        container.addSubview(empty)
        emptyView = empty
    }

    func updateStatus() {
        let status = store.session?.status ?? "Open a terminal in a project"
        statusLabel.stringValue = status
    }

    func attach(_ session: any TerminalSession) {
        emptyView?.removeFromSuperview()
        emptyView = nil
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        session.onStatusChange = { [weak self, weak session] in
            if self?.store.session == nil { self?.statusLabel.stringValue = session?.status ?? "No session" }
            else { self?.updateStatus() }
        }
        session.onCloseRequested = { [weak self] in self?.closeSession() }
        session.onActivate = { [weak self] in self?.showTerminal() }
        session.onInteractionLock = { [weak self] locked in self?.overlay?.setInteractionLock("terminal", locked) }
        statusLabel.stringValue = session.status
        window?.layoutIfNeeded()
        if let overlay { overlay.sessionChanged() }
        else {
            session.setPresented(true)
            window?.makeFirstResponder(session.view)
            session.setFocused(true)
        }
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
        showTerminal()
        overlay?.setInteractionLock("dialog", true)
        defer { overlay?.setInteractionLock("dialog", false) }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Open Terminal"
        if picker.runModal() == .OK, let url = picker.url { open(directory: url) }
    }
    @objc func openHome() { open(directory: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func showTerminal() {
        if let overlay { overlay.activate(); return }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let session = store.session {
            session.setPresented(true)
            window?.makeFirstResponder(session.view)
            session.setFocused(true)
        }
    }
    @objc func hideTerminal() {
        if let overlay { overlay.hide(); return }
        store.session?.setFocused(false)
        store.session?.setPresented(false)
        window?.orderOut(nil)
    }
    @objc func closeSession() {
        guard let session = store.session else { return }
        overlay?.setInteractionLock("dialog", true)
        defer { overlay?.setInteractionLock("dialog", false) }
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
        showEmptyState()
        overlay?.sessionChanged()
    }
    @objc func showAccessSettings() {
        if shortcut == nil { shortcut = ShortcutController() }
        shortcut?.showSettings(hoverEnabled: overlay?.state.hoverEnabled ?? true, setHover: { [weak self] value in
            UserDefaults.standard.set(value, forKey: "access.hover.v1")
            self?.overlay?.setHoverEnabled(value)
        })
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        if store.session?.isRunning == true {
            overlay?.setInteractionLock("dialog", true)
            defer { overlay?.setInteractionLock("dialog", false) }
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
        shortcut?.shutdown()
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
