// Native embedder callback patterns adapted from Ghostty.App.swift at the locked revision.
// Copyright (c) 2024 Mitchell Hashimoto. MIT; see ThirdParty/Notices/Ghostty-LICENSE.
import AppKit
import GhosttyKit

@MainActor
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var observers: [NSObjectProtocol] = []
    private var loadsPersonalConfiguration = true
    private(set) var lastConfigurationError: String?
    var onOpenConfiguration: (() -> Void)?
    var onConfigurationError: ((String) -> Void)?

    #if HARNESS_TESTS
    func appearanceReport() -> [String: Any] {
        guard let config else { return [:] }
        var report: [String: Any] = [:]
        for key in ["font-size"] {
            var value: Float = 0
            if ghostty_config_get(config, &value, key, UInt(key.utf8.count)) { report[key] = value }
        }
        var opacity: Double = 0
        if ghostty_config_get(config, &opacity, "background-opacity", 18) { report["background-opacity"] = opacity }
        for key in ["background", "foreground"] {
            var value = ghostty_config_color_s()
            if ghostty_config_get(config, &value, key, UInt(key.utf8.count)) {
                report[key] = String(format: "#%02x%02x%02x", value.r, value.g, value.b)
            }
        }
        report["inherited_no_color_removed"] = getenv("NO_COLOR") == nil
        return report
    }
    #endif

    init() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw TerminalFailure.unavailable("The app bundle has no Resources directory. Rebuild with scripts/build.sh.")
        }
        for relative in ["ghostty/shell-integration/zsh/ghostty-integration", "terminfo", "terminal.conf", "engine-revision.txt"] {
            guard FileManager.default.fileExists(atPath: resources.appendingPathComponent(relative).path) else {
                throw TerminalFailure.unavailable("Missing bundled resource: \(relative). Rebuild with scripts/build.sh; no external resource fallback is used.")
            }
        }
        let revision = try String(contentsOf: resources.appendingPathComponent("engine-revision.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision == "982fe90d941e4b4aab4905ffcbcfdea60bd83343" else {
            throw TerminalFailure.unavailable("Ghostty resources do not match this adapter's pinned revision.")
        }
        setenv("GHOSTTY_RESOURCES_DIR", resources.appendingPathComponent("ghostty").path, 1)
        setenv("GHOSTTY_LOG", "false", 1)
        // GUI launches from build tools can inherit NO_COLOR=1. This terminal
        // supports color; explicit Ghostty env settings and shell startup files
        // are applied later and can still opt out deliberately.
        unsetenv("NO_COLOR")
        // Pass only the executable name. Never let app arguments become engine configuration.
        let arg = strdup(CommandLine.arguments[0])!
        defer { free(arg) }
        var args: [UnsafeMutablePointer<CChar>?] = [arg, nil]
        guard ghostty_init(1, &args) == GHOSTTY_SUCCESS else {
            throw TerminalFailure.unavailable("Ghostty initialization failed.")
        }
        var qualification = false
        #if HARNESS_TESTS
        qualification = CommandLine.arguments.contains("--ssh-self-test") || CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--overlay-self-test") || CommandLine.arguments.contains("--settings-self-test")
        #endif
        loadsPersonalConfiguration = !qualification
        let config: ghostty_config_t
        do {
            config = try Self.makeConfiguration(loadPersonal: loadsPersonalConfiguration,
                                                file: loadsPersonalConfiguration ? TerminalConfiguration.fileURL : nil)
        } catch {
            // A broken user file must not prevent opening Settings to repair it.
            lastConfigurationError = "Configuration could not be loaded; using Ghostty defaults. \(error.localizedDescription)"
            config = try Self.makeConfiguration(loadPersonal: false, file: nil)
        }
        self.config = config
        var callbacks = ghostty_runtime_config_s()
        callbacks.userdata = Unmanaged.passUnretained(self).toOpaque()
        callbacks.supports_selection_clipboard = false
        callbacks.wakeup_cb = { pointer in
            guard let pointer else { return }
            // Wakeup may occur on an I/O thread. Runtime outlives every surface and queued tick.
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak runtime] in
                if let app = runtime?.app { ghostty_app_tick(app) }
            }
        }
        callbacks.action_cb = { app, target, action in
            MainActor.assumeIsolated {
                if let app, let pointer = ghostty_app_userdata(app) {
                    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
                    if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                        do { try runtime.reloadConfiguration() }
                        catch { runtime.onConfigurationError?(error.localizedDescription) }
                        return true
                    }
                    if action.tag == GHOSTTY_ACTION_OPEN_CONFIG {
                        runtime.onOpenConfiguration?()
                        return true
                    }
                    if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE && target.tag == GHOSTTY_TARGET_APP { return true }
                }
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface,
                      let pointer = ghostty_surface_userdata(surface) else { return false }
                return Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue().handle(action)
            }
        }
        callbacks.close_surface_cb = { pointer, alive in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let session = Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue()
                // Never free an exited surface on a later keypress. Its output stays inspectable.
                if alive { session.requestCloseFromEngine() } else if session.isRunning { session.didExit() }
            }
        }
        callbacks.read_clipboard_cb = { pointer, location, state, mimes, count, list in
            MainActor.assumeIsolated {
                guard let pointer, location == GHOSTTY_CLIPBOARD_STANDARD, !list else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
                let session = Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue()
                let supportsText = (0..<count).contains { index in mimes?[index].map { String(cString: $0) == "text/plain" } ?? false }
                guard supportsText, let text = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
                session.completeClipboard(text, state: state, confirmed: false)
                return GHOSTTY_CLIPBOARD_READ_STARTED
            }
        }
        callbacks.confirm_read_clipboard_cb = { pointer, contents, state, kind in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let session = Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue()
                guard let surface = session.surface else { return }
                guard kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE,
                      let contents, let items = contents.pointee.contents,
                      contents.pointee.contents_len == 1, let data = items[0].data else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                let text = String(decoding: UnsafeRawBufferPointer(start: data, count: items[0].len), as: UTF8.self)
                session.confirmPaste(text, state: state)
            }
        }
        callbacks.write_clipboard_cb = { pointer, location, contents, count, confirm in
            MainActor.assumeIsolated {
                guard let pointer, location == GHOSTTY_CLIPBOARD_STANDARD, let contents else { return }
                let session = Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue()
                var text: String?
                for index in 0..<count {
                    let item = contents[index]
                    if let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data {
                        text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
                    }
                }
                guard let text else { return }
                session.writeClipboard(text, confirm: confirm)
            }
        }
        guard let app = ghostty_app_new(&callbacks, config) else {
            ghostty_config_free(config)
            self.config = nil
            throw TerminalFailure.unavailable("Ghostty runtime creation failed.")
        }
        self.app = app
        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        ghostty_app_set_focus(app, NSApp.isActive)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSTextInputContext.keyboardSelectionDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let app = self?.app else { return }
                    ghostty_app_set_focus(app, NSApp.isActive)
                    if name == NSTextInputContext.keyboardSelectionDidChangeNotification { ghostty_app_keyboard_changed(app) }
                }
            })
        }
    }

    private static func makeConfiguration(loadPersonal: Bool, file: URL?) throws -> ghostty_config_t {
        guard let candidate = ghostty_config_new() else {
            throw TerminalFailure.unavailable("Ghostty configuration allocation failed.")
        }
        // Load shipped defaults even when an existing personal config predates
        // them. User bindings loaded below can still override these defaults.
        if let defaults = Bundle.main.url(forResource: "terminal", withExtension: "conf") {
            defaults.path.withCString { ghostty_config_load_file(candidate, $0) }
        }
        if loadPersonal { ghostty_config_load_default_files(candidate) }
        // Finish the inherited include chain before loading Knotch's global overrides.
        ghostty_config_load_recursive_files(candidate)
        if let file, FileManager.default.fileExists(atPath: file.path) {
            // Clear the already-consumed include list so recursive loading doesn't
            // reapply inherited values over the Knotch configuration.
            let reset = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-config-\(UUID().uuidString)")
            do {
                try "config-file =\n".write(to: reset, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: reset) }
                reset.path.withCString { ghostty_config_load_file(candidate, $0) }
                file.path.withCString { ghostty_config_load_file(candidate, $0) }
                ghostty_config_load_recursive_files(candidate)
            } catch {
                ghostty_config_free(candidate)
                throw error
            }
        }
        ghostty_config_finalize(candidate)
        var messages: [String] = []
        for index in 0..<ghostty_config_diagnostics_count(candidate) {
            if let message = ghostty_config_get_diagnostic(candidate, index).message {
                messages.append(String(cString: message))
            }
        }
        guard messages.isEmpty else {
            ghostty_config_free(candidate)
            throw TerminalFailure.unavailable(messages.joined(separator: "; "))
        }
        return candidate
    }

    func reloadConfiguration() throws {
        try reloadConfiguration(file: loadsPersonalConfiguration ? TerminalConfiguration.fileURL : nil)
    }

    private func reloadConfiguration(file: URL?) throws {
        guard let app else { throw TerminalFailure.unavailable("The terminal engine is not running.") }
        // Validate an entirely new config before changing any existing surface.
        let candidate = try Self.makeConfiguration(loadPersonal: loadsPersonalConfiguration, file: file)
        ghostty_app_update_config(app, candidate)
        if let config { ghostty_config_free(config) }
        config = candidate
        lastConfigurationError = nil
    }

    #if HARNESS_TESTS
    func reloadConfigurationForFixture(file: URL) throws { try reloadConfiguration(file: file) }
    #endif

    func shutdown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let app { ghostty_app_free(app); self.app = nil }
        if let config { ghostty_config_free(config); self.config = nil }
    }
}
