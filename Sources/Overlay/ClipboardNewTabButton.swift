import AppKit

/// The toolbar's New Tab button also accepts an app-owned Clipboard item.
/// The drop starts a shell first, then inserts the item without Return.
@MainActor
final class ClipboardNewTabButton: NSButton {
    var onClipboardDrop: ((UUID) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) != nil,
              onClipboardDrop != nil else { return [] }
        setDropHighlighted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) != nil && onClipboardDrop != nil
            ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlighted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        guard let id = ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) else { return false }
        return onClipboardDrop?(id) ?? false
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
    }
}
