import AppKit
import SwiftUI

/// The drag only exposes an opaque ID to this app. The terminal tab/view looks
/// up the bounded history entry after the drop, so no image bytes are placed in
/// the dragging pasteboard or copied to the user's ordinary clipboard.
struct ClipboardDragSource: NSViewRepresentable {
    let entry: ClipboardEntry
    let onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.entry = entry
        view.onDragChange = onDragChange
    }

    @MainActor
    final class DragView: NSView, NSDraggingSource {
        var entry: ClipboardEntry?
        var onDragChange: ((Bool) -> Void)?

        override func mouseDown(with event: NSEvent) {
            guard let entry else { return }
            let writer = NSPasteboardItem()
            writer.setString(entry.id.uuidString, forType: ClipboardTerminalDrop.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            let icon = entry.kind == .image
                ? entry.data.flatMap(NSImage.init(data:))
                : NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            item.setDraggingFrame(bounds, contents: icon ?? NSImage())
            onDragChange?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            onDragChange?(false)
        }
    }
}
