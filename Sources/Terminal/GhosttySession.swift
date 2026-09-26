import AppKit
import GhosttyKit

@MainActor
final class GhosttySession: TerminalSession {
    let id = UUID()
    let directory: URL
    let nativeView = GhosttyNativeView(frame: NSRect(x: 0, y: 0, width: 960, height: 480))
    var view: NSView { nativeView }
    private(set) var surface: ghostty_surface_t?
    private(set) var title = ""
    private var tabTitle: String?
    private var userTitle: String?
    var customTitle: String? {
        get { userTitle }
        set {
            let value = newValue.map(Self.sanitizeTitle).flatMap { $0.isEmpty ? nil : $0 }
            guard value != userTitle else { return }
            userTitle = value
            onStatusChange?()
        }
    }
    var displayTitle: String {
        if let customTitle { return customTitle }
        if let tabTitle { return tabTitle }
        if !title.isEmpty { return title }
        let fallback = directory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            ? "Home" : directory.lastPathComponent
        let safeTitle = Self.sanitizeTitle(fallback)
        return safeTitle.isEmpty ? "Terminal" : safeTitle
    }
    private(set) var status = "Session starting"
    private(set) var isRunning = false
    var onNotification: ((String, String) -> Void)?
    var onStatusChange: (() -> Void)?
    var onSystemDialogChange: ((Bool) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onNewTabRequested: (() -> Void)?
    var onActivate: (() -> Void)? { didSet { nativeView.onActivate = onActivate } }
    var onInput: (() -> Void)? { didSet { nativeView.onInput = onInput } }
    var onInteractionLock: ((Bool) -> Void)? {
        didSet {
            nativeView.onInteractionLock = { [weak self] locked in
                guard let self else { return }
                self.viewInteractionLocked = locked
                self.publishInteractionLock()
            }
            publishInteractionLock()
        }
    }
    private let runtime: GhosttyRuntime
    private var closeRequestQueued = false
    private var newTabRequestQueued = false
    private struct PendingPaste { let state: UnsafeMutableRawPointer? }
    private var pendingPastes: [UUID: PendingPaste] = [:]
    private var pendingClipboardWrites: Set<UUID> = []
    private var viewInteractionLocked = false
    private var presented = true

    /// Keep untrusted OSC titles single-line, visually unambiguous, and small in chrome.
    private static func sanitizeTitle(_ value: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in value.unicodeScalars.prefix(4096) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasSpace && !cleaned.isEmpty { cleaned.append(" ") }
                previousWasSpace = true
                continue
            }
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator {
                continue
            }
            cleaned.append(scalar)
            previousWasSpace = false
        }
        return String(String(cleaned).prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    private func setEngineTitle(_ pointer: UnsafePointer<CChar>?, forTab: Bool) {
        guard let pointer else { return }
        // The pinned engine currently caps its title, but bound the C-string read too.
        let length = strnlen(pointer, 4096)
        let value = Self.sanitizeTitle(String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self))
        if forTab {
            let next = value.isEmpty ? nil : value
            guard tabTitle != next else { return }
            tabTitle = next
        } else {
            guard title != value else { return }
            title = value
        }
        onStatusChange?()
    }

    private func publishInteractionLock() {
        onInteractionLock?(viewInteractionLocked || !pendingPastes.isEmpty || !pendingClipboardWrites.isEmpty)
    }

    private var canConfirmClipboard: Bool {
        presented && surface != nil && NSApp.isActive && nativeView.window?.isKeyWindow == true
    }

    init(runtime: GhosttyRuntime, directory: URL, testCommand: String? = nil) throws {
        self.runtime = runtime
        self.directory = directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalFailure.unavailable("The selected directory is unavailable. Choose an existing project folder.")
        }
        guard let app = runtime.app else { throw TerminalFailure.unavailable("Terminal runtime is unavailable.") }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(nativeView).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.wait_after_command = true
        // Shipping alpha uses the engine's system login-shell discovery. No launch-string injection.
        self.surface = directory.path.withCString { path in
            config.working_directory = path
            #if HARNESS_TESTS
            if let testCommand {
                return testCommand.withCString { command in
                    config.command = command
                    return ghostty_surface_new(app, &config)
                }
            }
            #endif
            return ghostty_surface_new(app, &config)
        }
        guard let surface else { throw TerminalFailure.unavailable("Ghostty could not create the native terminal surface.") }
        nativeView.surface = surface
        nativeView.syncGeometry()
        status = "Session running"
        isRunning = true
    }

    func setPresented(_ value: Bool) {
        presented = value
        nativeView.setPresented(value)
        if !value {
            let pasteStates = pendingPastes.values.map(\.state)
            pendingPastes.removeAll()
            pendingClipboardWrites.removeAll()
            viewInteractionLocked = false
            publishInteractionLock()
            if let surface {
                for state in pasteStates { ghostty_surface_deny_clipboard_request(surface, state) }
            }
        }
    }
    func setFocused(_ value: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, value)
    }
    func closeAfterConfirmation() {
        guard let surface else { return }
        let pasteStates = pendingPastes.values.map(\.state)
        pendingPastes.removeAll()
        pendingClipboardWrites.removeAll()
        viewInteractionLocked = false
        publishInteractionLock()
        for state in pasteStates { ghostty_surface_deny_clipboard_request(surface, state) }
        // The retained session is alive throughout synchronous engine destruction/callbacks.
        nativeView.surface = nil
        self.surface = nil
        ghostty_surface_free(surface)
        isRunning = false
        status = "Session closed"
    }
    func confirmPaste(_ text: String, state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        guard canConfirmClipboard, pendingPastes.isEmpty, pendingClipboardWrites.isEmpty else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        let requestID = UUID()
        pendingPastes[requestID] = PendingPaste(state: state)
        publishInteractionLock()
        // Leave the engine callback before running an AppKit modal loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.surface == surface, self.pendingPastes[requestID] != nil else { return }
            guard self.canConfirmClipboard else {
                if let pending = self.pendingPastes.removeValue(forKey: requestID) {
                    ghostty_surface_deny_clipboard_request(surface, pending.state)
                }
                self.publishInteractionLock()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Paste potentially executable text?"
            alert.informativeText = "This paste contains multiple lines or control characters. The terminal program may interpret them as commands."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Paste")
            self.onSystemDialogChange?(true)
            defer { self.onSystemDialogChange?(false) }
            let allowed = alert.runModal() == .alertSecondButtonReturn
            guard self.surface == surface, let pending = self.pendingPastes.removeValue(forKey: requestID) else { return }
            defer { self.publishInteractionLock() }
            if allowed && self.presented && NSApp.isActive {
                self.completeClipboard(text, state: pending.state, confirmed: true)
            }
            else { ghostty_surface_deny_clipboard_request(surface, pending.state) }
        }
    }

    func writeClipboard(_ text: String, confirm: Bool) {
        guard let surface else { return }
        guard confirm else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        // Programmatic writes never bring a hidden or inactive panel forward.
        guard canConfirmClipboard, pendingPastes.isEmpty, pendingClipboardWrites.isEmpty else { return }
        let requestID = UUID()
        pendingClipboardWrites.insert(requestID)
        publishInteractionLock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.surface == surface, self.pendingClipboardWrites.contains(requestID) else { return }
            guard self.canConfirmClipboard else {
                self.pendingClipboardWrites.remove(requestID)
                self.publishInteractionLock()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Allow this terminal program to replace the clipboard?"
            alert.addButton(withTitle: "Deny")
            alert.addButton(withTitle: "Allow once")
            self.onSystemDialogChange?(true)
            defer { self.onSystemDialogChange?(false) }
            let allowed = alert.runModal() == .alertSecondButtonReturn
            guard self.pendingClipboardWrites.remove(requestID) != nil else { return }
            defer { self.publishInteractionLock() }
            guard allowed, self.surface == surface, self.presented, NSApp.isActive else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func didExit(code: UInt32? = nil) {
        isRunning = false
        // The pinned macOS login wrapper reported 0 for a controlled `exit 7`.
        // Upstream Surface.zig documents this limitation. Never label it success.
        status = "Session ended · exit status unavailable"
        onStatusChange?()
    }
    func requestCloseFromEngine() {
        guard !closeRequestQueued else { return }
        closeRequestQueued = true
        let expected = surface
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closeRequestQueued = false
            guard self.surface != nil, self.surface == expected else { return }
            self.onCloseRequested?()
        }
    }
    func requestNewTabFromEngine() {
        guard !newTabRequestQueued else { return }
        newTabRequestQueued = true
        let expected = surface
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.newTabRequestQueued = false
            guard self.surface != nil, self.surface == expected else { return }
            self.onNewTabRequested?()
        }
    }
    func handle(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            func text(_ pointer: UnsafePointer<CChar>?) -> String {
                guard let pointer else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: pointer, count: strnlen(pointer, 4096)), as: UTF8.self)
            }
            let notification = action.action.desktop_notification
            onNotification?(text(notification.title), text(notification.body))
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            didExit(code: action.action.child_exited.exit_code)
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            requestCloseFromEngine()
            return true
        case GHOSTTY_ACTION_NEW_TAB:
            requestNewTabFromEngine()
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            setEngineTitle(action.action.set_title.title, forTab: false)
            return true
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            setEngineTitle(action.action.set_tab_title.title, forTab: true)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // Only honor an intentional terminal click while this surface owns focus.
            guard nativeView.window?.isKeyWindow == true,
                  let ptr = action.action.open_url.url else { return false }
            let value = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(action.action.open_url.len)), as: UTF8.self)
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
            NSWorkspace.shared.open(url)
            return true
        case GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SELECTION_CHANGED:
            // This metadata is not displayed in chrome.
            return true
        default:
            // Unsupported actions never activate; splits/export/inspector aren't in this alpha.
            return false
        }
    }
    func completeClipboard(_ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        "text/plain".withCString { mime in
            text.withCString { bytes in
                var content = ghostty_clipboard_content_s(mime: mime, data: bytes, len: text.utf8.count)
                withUnsafePointer(to: &content) { pointer in
                    var result = ghostty_clipboard_complete_s(contents: pointer, contents_len: 1, available: nil, available_len: 0, confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &result, state)
                }
            }
        }
    }
}
