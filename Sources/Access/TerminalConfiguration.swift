import AppKit
import Combine

/// One Knotch-owned file; the standalone Ghostty configuration is never edited.
@MainActor
final class TerminalConfiguration: ObservableObject {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.personal.Knotch", isDirectory: true)
            .appendingPathComponent("config")
    }

    let url: URL
    @Published private(set) var message = "Uses Ghostty syntax. Applies to all local and SSH tabs in Knotch."
    var reload: (() throws -> Void)?
    var beforeOpen: (() -> Void)?

    init(url: URL = TerminalConfiguration.fileURL) { self.url = url }

    func report(_ message: String) { self.message = message }

    func openConfiguration() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard let template = Bundle.main.url(forResource: "terminal", withExtension: "conf") else {
                    throw TerminalFailure.unavailable("The terminal config template is missing.")
                }
                // Never overwrite a user's existing file, including one created by an editor concurrently.
                do { try Data(contentsOf: template).write(to: url, options: .withoutOverwriting) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { /* Another writer created the configuration. */ }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            beforeOpen?()
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let error else { return }
                let detail = error.localizedDescription
                Task { @MainActor [weak self] in self?.message = "Could not open the config: \(detail)" }
            }
            message = "Save your changes, then choose Reload terminal config."
        } catch { message = error.localizedDescription }
    }

    func reloadConfiguration() {
        do {
            guard let reload else { throw TerminalFailure.unavailable("The terminal is not ready.") }
            try reload()
            message = "Configuration reloaded for all tabs. Existing sessions are still running."
        } catch {
            message = "Configuration was not applied. \(error.localizedDescription)"
        }
    }
}
