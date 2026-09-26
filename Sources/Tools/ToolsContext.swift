import AppKit

/// Balances native system dialogs with the overlay's focus and window level.
/// Feature services own their work; this object only coordinates presentation.
@MainActor
final class ToolsContext {
    var onDialogChange: ((Bool) -> Void)?
    private var dialogDepth = 0

    func beginDialog() {
        dialogDepth += 1
        if dialogDepth == 1 { onDialogChange?(true) }
    }

    func endDialog() {
        guard dialogDepth > 0 else { return }
        dialogDepth -= 1
        if dialogDepth == 0 { onDialogChange?(false) }
    }

    func withDialog<T>(_ body: () throws -> T) rethrows -> T {
        beginDialog()
        defer { endDialog() }
        return try body()
    }
}
