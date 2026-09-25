import AppKit

/// Pure presentation: the session store owns every terminal independently of this strip.
@MainActor
final class TerminalTabStrip: NSView, NSMenuDelegate {
    struct Item {
        let id: UUID
        let title: String
        let directory: String
        let running: Bool
        var isSettings = false
        var isClipboard = false
    }
    private final class TabButton: NSButton {
        var sessionID: UUID?
        var onRename: (() -> Void)?
        var onClipboardHover: (() -> Void)?
        var onClipboardDrop: ((UUID) -> Bool)?
        var onExternalHover: (() -> Void)?
        var onExternalDrop: ((NSPasteboard) -> Bool)?
        private var hoverTimer: Timer?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onRename?() } else { super.mouseDown(with: event) }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let isClipboardEntry = ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) != nil
            guard isClipboardEntry ? onClipboardDrop != nil
                    : (ExternalTerminalDrop.canAccept(sender.draggingPasteboard) && onExternalDrop != nil)
            else { return [] }
            setDropHighlighted(true)
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if isClipboardEntry { self?.onClipboardHover?() }
                    else { self?.onExternalHover?() }
                }
            }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            if ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) != nil {
                return onClipboardDrop == nil ? [] : .copy
            }
            return ExternalTerminalDrop.canAccept(sender.draggingPasteboard) && onExternalDrop != nil ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            hoverTimer?.invalidate()
            hoverTimer = nil
            setDropHighlighted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            hoverTimer?.invalidate()
            hoverTimer = nil
            setDropHighlighted(false)
            if let id = ClipboardTerminalDrop.entryID(from: sender.draggingPasteboard) {
                return onClipboardDrop?(id) ?? false
            }
            return onExternalDrop?(sender.draggingPasteboard) ?? false
        }

        private func setDropHighlighted(_ highlighted: Bool) {
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.backgroundColor = highlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
        }
    }
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onClipboardHover: ((UUID) -> Void)?
    var onClipboardDrop: ((UUID, UUID) -> Bool)?
    var onExternalHover: ((UUID) -> Void)?
    var onExternalDrop: ((NSPasteboard, UUID) -> Bool)?
    var onMenuLock: ((Bool) -> Void)?
    private let scroll = NSScrollView()
    private let document = NSView()
    private var selectedView: NSView?
    private var selectedID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityLabel("Terminal tabs")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ items: [Item], selected: UUID?) {
        let changedSelection = selectedID != selected
        selectedID = selected
        document.subviews.forEach { $0.removeFromSuperview() }
        selectedView = nil
        var x: CGFloat = 10
        for item in items {
            let active = item.id == selected
            let cell = NSView(frame: NSRect(x: x, y: 5, width: 200, height: 28))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 7
            cell.layer?.backgroundColor = NSColor(white: active ? 0.17 : 0.07, alpha: 1).cgColor
            let button = TabButton(frame: NSRect(x: 8, y: 0, width: 162, height: 28))
            button.sessionID = item.id
            button.title = item.title
            button.font = .systemFont(ofSize: 12, weight: active ? .medium : .regular)
            button.alignment = .left
            button.isBordered = false
            button.setButtonType(.toggle)
            button.state = active ? .on : .off
            button.cell?.lineBreakMode = .byTruncatingTail
            button.image = NSImage(systemSymbolName: item.isSettings ? "gearshape" : (item.isClipboard ? "doc.on.clipboard" : (item.running ? "terminal" : "stop.circle")), accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.contentTintColor = active ? .white : .secondaryLabelColor
            let status = item.isSettings ? "Preferences" : (item.isClipboard ? "Clipboard history" : (item.running ? "Shell running" : "Session ended"))
            button.toolTip = item.isSettings ? "Settings inside Knotch" : (item.isClipboard ? "Clipboard history inside Knotch" : "\(item.title)\n\(item.directory)\n\(status) · Double-click to rename")
            button.setAccessibilityLabel("\(item.title), \(status)\(active ? ", selected" : "")")
            button.target = self
            button.action = #selector(selectTab(_:))
            if !item.isSettings && !item.isClipboard {
                button.registerForDraggedTypes([ClipboardTerminalDrop.pasteboardType]
                                               + ExternalTerminalDrop.draggedTypes)
                button.onClipboardHover = { [weak self] in self?.onClipboardHover?(item.id) }
                button.onClipboardDrop = { [weak self] entryID in
                    self?.onClipboardDrop?(entryID, item.id) ?? false
                }
                button.onExternalHover = { [weak self] in self?.onExternalHover?(item.id) }
                button.onExternalDrop = { [weak self] board in
                    self?.onExternalDrop?(board, item.id) ?? false
                }
            }
            if !item.isSettings && !item.isClipboard { button.onRename = { [weak self] in self?.onRename?(item.id) } }
            if !item.isSettings && !item.isClipboard {
                let menu = NSMenu()
                menu.delegate = self
                for (title, action) in [("Rename Tab…", #selector(renameTab(_:))), ("Close Tab…", #selector(closeTab(_:)))] {
                    let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    entry.representedObject = item.id
                    entry.target = self
                    menu.addItem(entry)
                }
                button.menu = menu
            }
            cell.addSubview(button)
            if !item.isSettings && !item.isClipboard {
                let close = TabButton(frame: NSRect(x: 174, y: 2, width: 24, height: 24))
                close.sessionID = item.id
                close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
                close.isBordered = false
                close.contentTintColor = .secondaryLabelColor
                close.toolTip = "Close \(item.title)"
                close.setAccessibilityLabel("Close \(item.title)")
                close.target = self
                close.action = #selector(closeTab(_:))
                cell.addSubview(close)
            }
            document.addSubview(cell)
            if active { selectedView = cell }
            x += 206
        }
        document.frame = NSRect(x: 0, y: 0, width: max(bounds.width, x + 4), height: 38)
        needsLayout = true
        if changedSelection, let selectedView { document.scrollToVisible(selectedView.frame) }
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
    }
    @objc private func selectTab(_ sender: TabButton) {
        if let id = sender.sessionID { onSelect?(id) }
    }
    @objc private func closeTab(_ sender: Any) {
        if let id = (sender as? TabButton)?.sessionID ?? (sender as? NSMenuItem)?.representedObject as? UUID { onClose?(id) }
    }
    @objc private func renameTab(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onRename?(id) }
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuLock?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuLock?(false) }
}
