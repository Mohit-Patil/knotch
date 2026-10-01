import AppKit

// This executable tests the real tab controls in an offscreen, nonactivating
// panel. Drag payload parsing is outside this test's scope.
@MainActor enum ClipboardTerminalDrop {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.knotch.fixture")
    static func entryID(from: NSPasteboard) -> UUID? { nil }
}
@MainActor enum ExternalTerminalDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] = []
    static func canAccept(_ board: NSPasteboard) -> Bool { false }
}

@main @MainActor struct TerminalTabStripTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 38),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let strip = TerminalTabStrip(frame: NSRect(x: 0, y: 0, width: 640, height: 38))
        panel.contentView = strip
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        var selected: UUID?
        strip.onSelect = { selected = $0 }
        func controls(_ view: NSView) -> [NSButton] {
            view.subviews.flatMap { child -> [NSButton] in
                (child as? NSButton).map { [$0] } ?? controls(child)
            }
        }
        func button(_ title: String) -> NSButton {
            controls(strip).first { $0.title == title }!
        }
        for count in [2, 3, 8] {
            var items = (0..<count).map {
                TerminalTabStrip.Item(id: UUID(), title: "Terminal \($0)", directory: "/tmp", running: true)
            }
            let targetID = items[0].id
            strip.update(items, selected: items.last!.id)
            strip.layoutSubtreeIfNeeded()
            let target = button("Terminal 0")
            let parent = target.superview!
            let menu = target.menu!
            for tick in 0..<30 {
                items[1] = .init(id: items[1].id, title: "Codex working \(tick)", directory: "/tmp", running: true)
                strip.update(items, selected: items.last!.id)
                strip.layoutSubtreeIfNeeded()
                precondition(button("Terminal 0") === target && target.superview === parent,
                             "Title update detached the target control while a click could be tracking")
                precondition(target.menu === menu, "Status refresh replaced a potentially open menu")
            }
            let scroll = strip.subviews.compactMap { $0 as? NSScrollView }.first!
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            precondition(target.visibleRect.width > 0, "Old terminal must be visible for the click")
            // Deliver a native NSButton press. Refresh the other tab during its
            // tracking loop, then deliver release through AppKit's event queue.
            let point = target.convert(NSPoint(x: 20, y: 14), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            var refreshed = false
            let timer = Timer(timeInterval: 0.03, repeats: false) { _ in
                MainActor.assumeIsolated {
                    items[1] = .init(id: items[1].id, title: "Codex updated during click", directory: "/tmp", running: true)
                    strip.update(items, selected: items.last!.id)
                    strip.layoutSubtreeIfNeeded()
                    refreshed = true
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                    NSApp.postEvent(up, atStart: false)
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            selected = nil
            target.mouseDown(with: down)
            timer.invalidate()
            precondition(refreshed && selected == targetID, "Click was lost during a background title update")
            strip.update(items, selected: targetID)
            strip.layoutSubtreeIfNeeded()
            precondition(button("Terminal 0") === target && target.state == .on, "Selection replaced the control")
            strip.update(Array(items.dropFirst()), selected: items[1].id)
            precondition(parent.superview == nil, "Closed tab retained a clickable control")
            print("PASS: \(count) tabs retain controls and dispatch click through concurrent title update")
        }
        print("All terminal tab switching checks passed")
    }
}
