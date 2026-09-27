import AppKit

/// No engine C types escape this boundary. Presentation never owns process lifetime.
@MainActor
protocol TerminalSession: AnyObject {
    var id: UUID { get }
    var view: NSView { get }
    var directory: URL { get }
    var launchTarget: TerminalLaunchTarget { get }
    /// Title emitted by the terminal program. Empty until the first title action.
    var title: String { get }
    /// An app-level rename, which takes precedence over terminal title actions.
    var customTitle: String? { get set }
    var displayTitle: String { get }
    var status: String { get }
    var isRunning: Bool { get }
    var onStatusChange: (() -> Void)? { get set }
    var onCloseRequested: (() -> Void)? { get set }
    var onNewTabRequested: (() -> Void)? { get set }
    var onActivate: (() -> Void)? { get set }
    var onInput: (() -> Void)? { get set }
    var onInteractionLock: ((Bool) -> Void)? { get set }
    func setPresented(_ value: Bool)
    func setFocused(_ value: Bool)
    func closeAfterConfirmation()
}

extension TerminalSession {
    var launchTarget: TerminalLaunchTarget { .local(directory) }
}

enum TerminalFailure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): text }
    }
}

@MainActor
final class SessionStore {
    private(set) var sessions: [any TerminalSession] = []
    private(set) var selectedID: UUID?
    var session: (any TerminalSession)? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    func open(runtime: GhosttyRuntime, directory: URL) throws {
        try open(runtime: runtime, target: .local(directory))
    }

    func open(runtime: GhosttyRuntime, target: TerminalLaunchTarget) throws {
        let opened = try GhosttySession(runtime: runtime, target: target)
        sessions.append(opened)
        selectedID = opened.id
    }

    @discardableResult
    func select(id: UUID) -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    @discardableResult
    func closeAfterConfirmation(id: UUID? = nil) -> Bool {
        guard let id = id ?? selectedID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        let closing = sessions.remove(at: index)
        if selectedID == id {
            selectedID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
        closing.closeAfterConfirmation()
        return true
    }

    func closeAllAfterConfirmation() {
        let closing = sessions
        sessions.removeAll()
        selectedID = nil
        for session in closing { session.closeAfterConfirmation() }
    }
    #if HARNESS_TESTS
    func adoptFixture(_ session: any TerminalSession) {
        precondition(!sessions.contains(where: { $0.id == session.id }))
        sessions.append(session)
        selectedID = session.id
    }
    #endif
}
