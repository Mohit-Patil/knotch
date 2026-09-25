import AppKit
import GhosttyKit

@MainActor
final class GhosttySession: TerminalSession {
    let id = UUID()
    let directory: URL
    let nativeView = GhosttyNativeView(frame: NSRect(x: 0, y: 0, width: 960, height: 480))
    var view: NSView { nativeView }
    private(set) var surface: ghostty_surface_t?
    private(set) var status = "Session starting"
    private(set) var isRunning = false
    var onStatusChange: (() -> Void)?
    var onCloseRequested: (() -> Void)?
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
    private struct PendingPaste { let state: UnsafeMutableRawPointer? }
    private var pendingPastes: [UUID: PendingPaste] = [:]
    private var pendingClipboardWrites: Set<UUID> = []
    private var viewInteractionLocked = false
    private var presented = true

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
    func handle(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            didExit(code: action.action.child_exited.exit_code)
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            requestCloseFromEngine()
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // Only honor an intentional terminal click while this surface owns focus.
            guard nativeView.window?.isKeyWindow == true,
                  let ptr = action.action.open_url.url else { return false }
            let value = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(action.action.open_url.len)), as: UTF8.self)
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
            NSWorkspace.shared.open(url)
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SELECTION_CHANGED:
            // Metadata intentionally not lifted into alpha chrome.
            return true
        default:
            // Notifications never activate; tabs/splits/export/inspector aren't in this alpha.
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
