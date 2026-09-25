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
    let statusLabel = NSTextField(labelWithString: "Terminal")
    private var closeButton: NSButton?
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
        #if HARNESS_TESTS
        if CommandLine.arguments.contains("--config-self-test"), let runtime {
            let data = try! JSONSerialization.data(withJSONObject: runtime.appearanceReport(), options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            runtime.shutdown()
            exit(0)
        }
        #endif
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
            // Launch at the notch. Only a click/shortcut or explicit directory launch activates.
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
        appMenu.addItem(withTitle: "Minimise Terminal", action: #selector(hideTerminal), keyEquivalent: "h").target = self
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
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        let terminalIcon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!)
        terminalIcon.contentTintColor = .secondaryLabelColor
        terminalIcon.setAccessibilityElement(false)
        toolbar.addArrangedSubview(terminalIcon)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        for (symbol, title, action) in [
            ("slider.horizontal.3", "Access & Shortcut…", #selector(showAccessSettings)),
            ("chevron.up", "Minimise Terminal", #selector(hideTerminal)),
            ("xmark", "Close Session…", #selector(closeSession))
        ] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            if action == #selector(closeSession) { closeButton = button; button.isEnabled = false }
            toolbar.addArrangedSubview(button)
        }
        for view in [toolbar, container] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            terminalIcon.widthAnchor.constraint(equalToConstant: 18),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.6),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        showEmptyState()
        return root
    }

    func showEmptyState() {
        let empty = NSHostingView(rootView: VStack(spacing: 22) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                Button(action: { [weak self] in self?.chooseProject() }) {
                    Label("Open Project…", systemImage: "folder")
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                Button(action: { [weak self] in self?.openHome() }) {
                    Label("Home Shell", systemImage: "terminal")
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30))
        empty.frame = container.bounds
        empty.autoresizingMask = [.width, .height]
        container.addSubview(empty)
        emptyView = empty
        updateStatus()
    }

    func updateStatus() {
        guard let session = store.session else {
            statusLabel.stringValue = "Terminal"
            statusLabel.toolTip = nil
            closeButton?.isEnabled = false
            return
        }
        let name = session.directory == FileManager.default.homeDirectoryForCurrentUser
            ? "Home" : session.directory.lastPathComponent
        statusLabel.stringValue = session.isRunning ? name : "\(name) · \(session.status)"
        statusLabel.toolTip = session.directory.path
        closeButton?.isEnabled = true
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
        session.onInput = { [weak self] in self?.overlay?.send(.terminalInput) }
        session.onInteractionLock = { [weak self] locked in self?.overlay?.setInteractionLock("terminal", locked) }
        updateStatus()
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
        showEmptyState()
        overlay?.sessionChanged()
    }
    @objc func showAccessSettings() {
        if shortcut == nil { shortcut = ShortcutController() }
        overlay?.setInteractionLock("settings", true)
        shortcut?.onSettingsClosed = { [weak self] in self?.overlay?.setInteractionLock("settings", false) }
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
