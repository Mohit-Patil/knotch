import AppKit

/// No engine C types escape this boundary. Presentation never owns process lifetime.
@MainActor
protocol TerminalSession: AnyObject {
    var id: UUID { get }
    var view: NSView { get }
    var directory: URL { get }
    var status: String { get }
    var isRunning: Bool { get }
    var onStatusChange: (() -> Void)? { get set }
    var onCloseRequested: (() -> Void)? { get set }
    var onActivate: (() -> Void)? { get set }
    var onInteractionLock: ((Bool) -> Void)? { get set }
    func setPresented(_ value: Bool)
    func setFocused(_ value: Bool)
    func closeAfterConfirmation()
}

enum TerminalFailure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): text }
    }
}

@MainActor
final class SessionStore {
    private(set) var session: (any TerminalSession)?
    func open(runtime: GhosttyRuntime, directory: URL) throws {
        guard session == nil else { throw TerminalFailure.unavailable("Close the current session before opening another project.") }
        session = try GhosttySession(runtime: runtime, directory: directory)
    }
    func closeAfterConfirmation() {
        session?.closeAfterConfirmation()
        session = nil
    }
    #if HARNESS_TESTS
    func adoptFixture(_ session: any TerminalSession) { precondition(self.session == nil); self.session = session }
    #endif
}
