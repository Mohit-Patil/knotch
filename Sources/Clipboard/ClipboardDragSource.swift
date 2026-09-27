import AppKit
import SwiftUI

/// The drag only exposes an opaque ID to this app. The terminal tab/view looks
/// up the bounded history entry after the drop, so no image bytes are placed in
/// the dragging pasteboard or copied to the user's ordinary clipboard.
struct ClipboardDragSource: NSViewRepresentable {
    let entry: ClipboardEntry
    let onDragChange: (Bool) -> Void
    var onHoverChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> DragView {
        let view = DragView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.setEntry(entry)
        view.onDragChange = onDragChange
        view.onHoverChange = onHoverChange
    }

    @MainActor
    final class DragView: NSView, NSDraggingSource {
        var entry: ClipboardEntry?
        private var preview: NSImage?
        private var previewTask: Task<Void, Never>?

        func setEntry(_ value: ClipboardEntry) {
            let changed = entry?.id != value.id
            entry = value
            guard changed else { return }
            previewTask?.cancel()
            preview = nil
            guard value.kind == .image else { return }
            previewTask = Task { [weak self] in
                let pixels = await ClipboardThumbnails.shared.image(for: value)
                guard !Task.isCancelled else { return }
                self?.preview = pixels.map { NSImage(cgImage: $0, size: .zero) }
            }
        }
        var onDragChange: ((Bool) -> Void)?
        var onHoverChange: ((Bool) -> Void)?
        private var hoverTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            super.updateTrackingAreas()
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

        override func mouseDown(with event: NSEvent) {
            guard let entry else { return }
            let writer = NSPasteboardItem()
            writer.setString(entry.id.uuidString, forType: ClipboardTerminalDrop.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            let icon = entry.kind == .image
                ? preview
                : NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            let point = convert(event.locationInWindow, from: nil)
            let size = NSSize(width: min(bounds.width, 180), height: min(bounds.height, 120))
            let frame = NSRect(x: max(0, min(bounds.width - size.width, point.x - size.width / 2)),
                               y: max(0, min(bounds.height - size.height, point.y - size.height / 2)),
                               width: size.width, height: size.height)
            item.setDraggingFrame(frame, contents: icon ?? NSImage())
            onDragChange?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            onDragChange?(false)
            if let window {
                let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                onHoverChange?(bounds.contains(point))
            } else {
                onHoverChange?(false)
            }
        }
    }
}
