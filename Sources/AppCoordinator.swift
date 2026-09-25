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
    private let tabs = TerminalTabStrip()
    private let settingsID = UUID()
    private let clipboardID = UUID()
    private var settingsSelected = false
    private var clipboardSelected = false
    private var settingsView: NSView?
    private var clipboardView: NSView?
    private var clipboard: ClipboardHistory?
    private var clipboardDragActive = false
    private var retainedDragSourceView: NSView?
    private let clipboardImageExport = ClipboardImageExport()
    private var externalDropFolders: [URL] = []
    private var savedTerminalPanelSize: CGSize?
    private var runningQualification = false
    private var tabHeight: NSLayoutConstraint?
    private weak var attachedSession: (any TerminalSession)?
    var quitting = false

    #if HARNESS_TESTS
    func useClipboardForFixture(_ history: ClipboardHistory) { clipboard?.stop(); clipboard = history }
    var isClipboardSelectedForFixture: Bool { clipboardSelected }
    func hoverClipboardTabForFixture(sessionID: UUID) {
        clipboardDragChanged(true)
        selectSession(id: sessionID)
    }
    func acceptClipboardDropForFixture(entryID: UUID, sessionID: UUID) -> Bool {
        clipboardDragChanged(true)
        defer { clipboardDragChanged(false) }
        return acceptClipboardDrop(entryID: entryID, sessionID: sessionID)
    }
    func acceptExternalTerminalDropForFixture(_ board: NSPasteboard, sessionID: UUID) -> Bool {
        acceptExternalDrop(board, destination: .terminal(sessionID))
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let harness = CommandLine.arguments.contains("--harness") || CommandLine.arguments.contains("--self-test")
        var qualification = false
        #if HARNESS_TESTS
        qualification = CommandLine.arguments.contains("--overlay-self-test")
            || CommandLine.arguments.contains("--settings-self-test")
            || CommandLine.arguments.contains("--clipboard-self-test")
        #endif
        runningQualification = qualification || harness
        if !runningQualification { savedTerminalPanelSize = Self.loadTerminalPanelSize() }
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
        if !runningQualification {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.personal.Knotch", isDirectory: true)
            clipboard = ClipboardHistory(storageURL: folder.appendingPathComponent("clipboard-history.json"),
                                         persistsHistory: UserDefaults.standard.object(forKey: "clipboard.persist.v1") as? Bool ?? true)
            clipboard?.start()
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
            let controller = OverlayController(content: makeContent(),
                                               userPanelSize: savedTerminalPanelSize,
                                               sessionProvider: { [weak self] in
                guard let self, !self.settingsSelected, !self.clipboardSelected else { return nil }
                return self.store.session
            })
            overlay = controller
            window = controller.panel
            controller.onExternalDrop = { [weak self] board in
                self?.acceptExternalDrop(board, destination: .clipboard) ?? false
            }
            controller.onExternalDragToHandle = { [weak self] in self?.showClipboard() }
            controller.onPresentationChange = { [weak self] _ in self?.updateStatus() }
            controller.onTerminalPanelSizeCommit = { [weak self] size in
                self?.setTerminalPanelSize(size)
            }
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
        if CommandLine.arguments.contains("--settings-self-test") {
            Task { @MainActor in await HarnessQualification.runSettings(coordinator: self) }
            return
        }
        if CommandLine.arguments.contains("--clipboard-self-test") {
            Task { @MainActor in await ClipboardQualification.run(coordinator: self) }
            return
        }
        #endif
        if let index = CommandLine.arguments.firstIndex(of: "--directory"), index + 1 < CommandLine.arguments.count {
            open(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        if harness { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    private static func loadTerminalPanelSize() -> CGSize? {
        guard let values = UserDefaults.standard.array(forKey: "panel.terminal-size.v1") as? [Double],
              values.count == 2, values.allSatisfy({ $0.isFinite }),
              (200...10_000).contains(values[0]), (120...10_000).contains(values[1]) else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    private func setTerminalPanelSize(_ size: CGSize?) {
        savedTerminalPanelSize = size
        overlay?.setUserPanelSize(size)
        guard !runningQualification else { return }
        if let size {
            UserDefaults.standard.set([Double(size.width), Double(size.height)],
                                      forKey: "panel.terminal-size.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "panel.terminal-size.v1")
        }
    }

    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Terminal", action: #selector(showTerminal), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
        appMenu.addItem(withTitle: "Rename Tab…", action: #selector(renameSelectedTab), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Open Project…", action: #selector(chooseProject), keyEquivalent: "o").target = self
        appMenu.addItem(withTitle: "Open Home Shell", action: #selector(openHome), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Clipboard", action: #selector(showClipboard), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Minimise Terminal", action: #selector(hideTerminal), keyEquivalent: "h").target = self
        appMenu.addItem(withTitle: "Close Session…", action: #selector(closeSession), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: "Settings", action: #selector(showAccessSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        for number in 1...9 {
            let item = appMenu.addItem(withTitle: "Select Tab \(number)", action: #selector(selectNumberedTab(_:)), keyEquivalent: String(number))
            item.tag = number - 1
            item.target = self
        }
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
            ("plus", "New Tab", #selector(newTab)),
            ("folder.badge.plus", "New Project Tab…", #selector(chooseProject)),
            ("doc.on.clipboard", "Clipboard", #selector(showClipboard)),
            ("gearshape", "Settings", #selector(showAccessSettings)),
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
        tabs.onSelect = { [weak self] id in
            guard let self else { return }
            if id == self.settingsID { self.showAccessSettings() }
            else if id == self.clipboardID { self.showClipboard() }
            else { self.selectSession(id: id) }
        }
        tabs.onClose = { [weak self] in self?.closeTab(id: $0) }
        tabs.onRename = { [weak self] in self?.renameSession(id: $0) }
        tabs.onClipboardHover = { [weak self] sessionID in
            guard let self, self.clipboardDragActive else { return }
            self.selectSession(id: sessionID)
        }
        tabs.onClipboardDrop = { [weak self] entryID, sessionID in
            self?.acceptClipboardDrop(entryID: entryID, sessionID: sessionID) ?? false
        }
        tabs.onExternalHover = { [weak self] sessionID in self?.selectSession(id: sessionID) }
        tabs.onExternalDrop = { [weak self] board, sessionID in
            self?.acceptExternalDrop(board, destination: .terminal(sessionID)) ?? false
        }
        tabs.onMenuLock = { [weak self] open in
            self?.overlay?.setInteractionLock("tab-menu", open)
            self?.overlay?.setSystemDialogPresented(open)
        }
        tabHeight = tabs.heightAnchor.constraint(equalToConstant: 0)
        tabHeight?.isActive = true
        for view in [toolbar, tabs, container] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            terminalIcon.widthAnchor.constraint(equalToConstant: 18),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.28),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        showEmptyState()
        return root
    }

    func showEmptyState() {
        emptyView?.removeFromSuperview()
        let empty = NSHostingView(rootView: VStack(spacing: 22) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                Button(action: { [weak self] in self?.chooseProject() }) {
                    Label("Open Project…", systemImage: "folder")
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(.white, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                Button(action: { [weak self] in self?.openHome() }) {
                    Label("Home Shell", systemImage: "terminal")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
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
        tabs.isHidden = false
        tabHeight?.constant = 38
        var items: [TerminalTabStrip.Item] = store.sessions.map {
            .init(id: $0.id, title: $0.displayTitle, directory: $0.directory.path, running: $0.isRunning)
        }
        items.append(.init(id: clipboardID, title: "Clipboard", directory: "", running: false, isClipboard: true))
        items.append(.init(id: settingsID, title: "Settings", directory: "", running: false, isSettings: true))
        tabs.update(items, selected: settingsSelected ? settingsID : (clipboardSelected ? clipboardID : store.selectedID))
        if settingsSelected {
            statusLabel.stringValue = "Settings"
            statusLabel.toolTip = nil
            closeButton?.isEnabled = false
            return
        }
        if clipboardSelected {
            statusLabel.stringValue = "Clipboard"
            statusLabel.toolTip = nil
            closeButton?.isEnabled = false
            return
        }
        guard let session = store.session else {
            statusLabel.stringValue = "Terminal"
            statusLabel.toolTip = nil
            closeButton?.isEnabled = false
            return
        }
        let name = session.displayTitle
        statusLabel.stringValue = session.isRunning ? name : "\(name) · \(session.status)"
        statusLabel.toolTip = session.directory.path
        closeButton?.isEnabled = true
    }

    func attach(_ session: any TerminalSession) {
        if settingsSelected { overlay?.setInteractionLock("settings-recording", false) }
        settingsSelected = false
        clipboardSelected = false
        settingsView?.removeFromSuperview()
        settingsView = nil
        if clipboardDragActive {
            // AppKit's drag source must stay attached to its window until the
            // session ends. The terminal is placed above it for the drop.
            retainedDragSourceView = clipboardView
        } else {
            clipboardView?.removeFromSuperview()
        }
        clipboardView = nil
        if attachedSession !== session {
            attachedSession?.setFocused(false)
            attachedSession?.setPresented(false)
            attachedSession?.view.removeFromSuperview()
            overlay?.setInteractionLock("terminal", false)
        }
        attachedSession = session
        emptyView?.removeFromSuperview()
        emptyView = nil
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        if session.view.superview !== container { container.addSubview(session.view) }
        let id = session.id
        session.onStatusChange = { [weak self] in self?.updateStatus() }
        session.onCloseRequested = { [weak self] in self?.closeTab(id: id) }
        session.onNewTabRequested = { [weak self, weak session] in
            guard let self, self.store.selectedID == id, self.store.sessions.contains(where: { $0.id == id }), let session else { return }
            self.open(directory: session.directory)
        }
        session.onActivate = { [weak self] in self?.selectSession(id: id) }
        if let ghostty = session as? GhosttySession {
            ghostty.nativeView.onClipboardDrop = { [weak self] entryID in
                self?.acceptClipboardDrop(entryID: entryID, sessionID: id) ?? false
            }
            ghostty.nativeView.onExternalDrop = { [weak self] board in
                self?.acceptExternalDrop(board, destination: .terminal(id)) ?? false
            }
            ghostty.nativeView.onExternalDrag = { [weak self] entered in
                self?.overlay?.externalDragChanged(entered)
            }
        }
        session.onInput = { [weak self] in
            guard let self, !self.settingsSelected, !self.clipboardSelected, self.store.selectedID == id else { return }
            self.overlay?.send(.terminalInput)
        }
        session.onInteractionLock = { [weak self] locked in
            guard let self, !self.settingsSelected, !self.clipboardSelected, self.store.selectedID == id else { return }
            self.overlay?.setInteractionLock("terminal", locked)
        }
        updateStatus()
        window?.layoutIfNeeded()
        if let overlay { overlay.sessionChanged() }
        else {
            session.setPresented(true)
            window?.makeFirstResponder(session.view)
            session.setFocused(true)
        }
    }

    func selectSession(id: UUID) {
        guard store.sessions.contains(where: { $0.id == id }) else { return }
        store.select(id: id)
        if let session = store.session { attach(session) }
        showTerminal()
    }
    @objc func newTab() { open(directory: store.session?.directory ?? FileManager.default.homeDirectoryForCurrentUser) }
    @objc func selectNumberedTab(_ sender: NSMenuItem) {
        guard store.sessions.indices.contains(sender.tag) else { return }
        selectSession(id: store.sessions[sender.tag].id)
    }
    @objc func renameSelectedTab() {
        if !settingsSelected, !clipboardSelected, let id = store.selectedID { renameSession(id: id) }
    }
    private func runAppDialog<T>(_ body: () -> T) -> T {
        overlay?.setInteractionLock("dialog", true)
        overlay?.setSystemDialogPresented(true)
        defer {
            overlay?.setSystemDialogPresented(false)
            overlay?.setInteractionLock("dialog", false)
        }
        return body()
    }
    func renameSession(id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        overlay?.setInteractionLock("rename", true)
        defer { showTerminal(); overlay?.setInteractionLock("rename", false) }
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.informativeText = "Leave blank to use the terminal title."
        let field = NSTextField(string: session.customTitle ?? "")
        field.placeholderString = session.displayTitle
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard runAppDialog({ alert.runModal() }) == .alertFirstButtonReturn,
              store.sessions.contains(where: { $0.id == id }) else { return }
        session.customTitle = field.stringValue
        updateStatus()
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
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Open Terminal"
        if runAppDialog({ picker.runModal() }) == .OK, let url = picker.url { open(directory: url) }
        else { showTerminal() }
    }
    @objc func openHome() { open(directory: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func showTerminal() {
        if let overlay { overlay.activate(); return }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if !settingsSelected, !clipboardSelected, let session = store.session {
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
        if !settingsSelected, !clipboardSelected, let id = store.selectedID { closeTab(id: id) }
    }
    func closeTab(id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        if session.isRunning {
            let alert = NSAlert()
            alert.messageText = "End “\(session.displayTitle)”?"
            alert.informativeText = "This tab’s shell and running tools will end. Other tabs keep running."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "End Session")
            guard runAppDialog({ alert.runModal() }) == .alertSecondButtonReturn else {
                showTerminal()
                return
            }
        }
        session.view.removeFromSuperview()
        store.closeAfterConfirmation(id: id)
        if settingsSelected || clipboardSelected { updateStatus(); return }
        if let selected = store.session { attach(selected) }
        else {
            attachedSession = nil
            showEmptyState()
            overlay?.sessionChanged()
        }
    }
    @objc func showClipboard() {
        guard let clipboard else { return }
        if !clipboardSelected {
            attachedSession?.setFocused(false)
            attachedSession?.setPresented(false)
            attachedSession?.view.removeFromSuperview()
            attachedSession = nil
            window?.makeFirstResponder(nil)
            overlay?.setInteractionLock("terminal", false)
            overlay?.setInteractionLock("settings-recording", false)
            settingsView?.removeFromSuperview()
            settingsView = nil
            settingsSelected = false
            emptyView?.removeFromSuperview()
            emptyView = nil
            clipboardSelected = true
            let view = NSHostingView(rootView: ClipboardView(history: clipboard,
                                                              onDragChange: { [weak self] dragging in
                self?.clipboardDragChanged(dragging)
            }))
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            clipboardView = view
            updateStatus()
            overlay?.sessionChanged()
        }
        clipboard.captureChange()
        showTerminal()
    }

    private func clipboardDragChanged(_ dragging: Bool) {
        clipboardDragActive = dragging
        overlay?.setInteractionLock("clipboard-drag", dragging)
        if !dragging {
            retainedDragSourceView?.removeFromSuperview()
            retainedDragSourceView = nil
        }
    }

    private func acceptClipboardDrop(entryID: UUID, sessionID: UUID) -> Bool {
        guard clipboardDragActive,
              let entry = clipboard?.entries.first(where: { $0.id == entryID }),
              store.sessions.contains(where: { $0.id == sessionID && $0.isRunning }) else { return false }
        // Complete AppKit's drag first. This also lets the source release its
        // presentation lock before any unsafe-paste confirmation is shown.
        Task { @MainActor [weak self] in self?.insertClipboardEntry(entry, into: sessionID) }
        return true
    }

    private func insertClipboardEntry(_ entry: ClipboardEntry, into sessionID: UUID) {
        guard let session = store.sessions.first(where: { $0.id == sessionID && $0.isRunning }) as? GhosttySession else { return }
        let text: String
        do {
            switch entry.kind {
            case .text, .link, .richText:
                guard let value = entry.text, !value.isEmpty else { return }
                text = value
            case .files:
                guard let paths = entry.fileURLs, !paths.isEmpty,
                      paths.allSatisfy(\.isFileURL) else { return }
                let escaped = paths.compactMap { ClipboardTerminalDrop.escapedPath($0.path) }
                guard escaped.count == paths.count else { return }
                text = escaped.joined(separator: " ")
            case .image:
                let path = try clipboardImageExport.path(for: entry)
                guard let escaped = ClipboardTerminalDrop.escapedPath(path) else { return }
                text = escaped
            }
        } catch {
            showError(error)
            return
        }
        if ClipboardTerminalDrop.needsConfirmation(text) {
            let alert = NSAlert()
            alert.messageText = "Insert multiline or control text into the terminal?"
            alert.informativeText = "The terminal program may interpret this text as commands. Dropping does not press Return."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Insert")
            guard runAppDialog({ alert.runModal() }) == .alertSecondButtonReturn else { return }
        }
        selectSession(id: sessionID)
        _ = session.nativeView.insertDroppedText(text)
    }

    private enum ExternalDropDestination {
        case clipboard
        case terminal(UUID)
    }

    @discardableResult
    private func acceptExternalDrop(_ board: NSPasteboard, destination: ExternalDropDestination) -> Bool {
        guard let content = ExternalTerminalDrop.content(from: board) else {
            showError(TerminalFailure.unavailable("This dragged image or file could not be read."))
            return false
        }
        switch content {
        case .files(let urls):
            if urls.count == 1, let image = ExternalTerminalDrop.image(at: urls[0]) {
                receiveExternalEntry(image, destination: destination)
            } else {
                receiveExternalEntry(ClipboardEntry(kind: .files, fileURLs: urls), destination: destination)
            }
        case .image(let data, _):
            guard let entry = ExternalTerminalDrop.image(from: data) else {
                showError(TerminalFailure.unavailable("This screenshot exceeds the 4 MB clipboard image limit."))
                return false
            }
            receiveExternalEntry(entry, destination: destination)
        case .promises(let receivers):
            guard receivers.count == 1 else { return false }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Knotch-Screenshot-Drop-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                externalDropFolders.append(folder)
            } catch {
                showError(error)
                return false
            }
            receivers[0].receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) {
                [weak self] fileURL, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error { self.showError(error); return }
                    guard let data = try? Data(contentsOf: fileURL),
                          let entry = ExternalTerminalDrop.image(from: data) else {
                        self.showError(TerminalFailure.unavailable("The screenshot could not be saved as an image under 4 MB."))
                        return
                    }
                    self.receiveExternalEntry(entry, destination: destination)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        return true
    }

    private func receiveExternalEntry(_ candidate: ClipboardEntry, destination: ExternalDropDestination) {
        guard let entry = clipboard?.addDropped(candidate) else { return }
        switch destination {
        case .clipboard:
            showClipboard()
        case .terminal(let sessionID):
            insertClipboardEntry(entry, into: sessionID)
        }
    }
    @objc func showAccessSettings() {
        if shortcut == nil { shortcut = ShortcutController() }
        guard let shortcut else { return }
        if settingsView == nil {
            let sizing = overlay?.terminalSizeOptions()
            settingsView = shortcut.makeSettingsView(
                hoverEnabled: overlay?.state.hoverEnabled ?? true,
                setHover: { [weak self] value in
                    UserDefaults.standard.set(value, forKey: "access.hover.v1")
                    self?.overlay?.setHoverEnabled(value)
                },
                onRecordingChange: { [weak self] recording in
                    self?.overlay?.setInteractionLock("settings-recording", recording)
                },
                panelSize: sizing?.current ?? CGSize(width: 720, height: 550),
                defaultPanelSize: sizing?.defaultSize ?? CGSize(width: 720, height: 550),
                maximumPanelSize: sizing?.maximum ?? CGSize(width: 1920, height: 1080),
                panelSizeIsCustom: savedTerminalPanelSize != nil,
                setPanelSize: { [weak self] size in self?.setTerminalPanelSize(size) },
                clipboardPersists: clipboard?.persistsHistory ?? false,
                setClipboardPersists: { [weak self] enabled in
                    self?.clipboard?.setPersistsHistory(enabled)
                    UserDefaults.standard.set(enabled, forKey: "clipboard.persist.v1")
                })
        }
        guard let settingsView else { return }
        if !settingsSelected {
            attachedSession?.setFocused(false)
            attachedSession?.setPresented(false)
            attachedSession?.view.removeFromSuperview()
            attachedSession = nil
            window?.makeFirstResponder(nil)
            overlay?.setInteractionLock("terminal", false)
            emptyView?.removeFromSuperview()
            emptyView = nil
            clipboardView?.removeFromSuperview()
            clipboardView = nil
            clipboardSelected = false
            settingsSelected = true
            settingsView.frame = container.bounds
            settingsView.autoresizingMask = [.width, .height]
            container.addSubview(settingsView)
            updateStatus()
            overlay?.sessionChanged()
        }
        showTerminal()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        if store.sessions.contains(where: { $0.isRunning }) {
            let alert = NSAlert()
            alert.messageText = "Quit and end all terminal sessions?"
            alert.informativeText = "Sessions do not survive app exit. Hiding keeps your shell and tools running."
            alert.addButton(withTitle: "Keep App Running")
            alert.addButton(withTitle: "Hide Instead")
            alert.addButton(withTitle: "Quit and End All Sessions")
            switch runAppDialog({ alert.runModal() }) {
            case .alertThirdButtonReturn: break
            case .alertSecondButtonReturn: hideTerminal(); return .terminateCancel
            default: showTerminal(); return .terminateCancel
            }
        }
        store.closeAllAfterConfirmation()
        clipboardImageExport.cleanUp()
        for folder in externalDropFolders { try? FileManager.default.removeItem(at: folder) }
        clipboard?.stop()
        shortcut?.shutdown()
        runtime?.shutdown()
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideTerminal(); return false }
    func windowDidBecomeKey(_ notification: Notification) { if !settingsSelected && !clipboardSelected { store.session?.setFocused(true) } }
    func windowDidResignKey(_ notification: Notification) { store.session?.setFocused(false) }
    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        _ = runAppDialog { alert.runModal() }
    }
}
