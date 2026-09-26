import AppKit

/// Layout only. The coordinator and session store retain ownership of terminals.
@MainActor
final class TerminalWorkspaceView: NSView {
    let content: NSView
    private(set) var shelf: NSView?
    var showsShelf = true { didSet { needsLayout = true } }
    var preservesDragSource = false
    private(set) var visibleShelfHeight: CGFloat = 0

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installShelf(_ view: NSView) {
        shelf?.removeFromSuperview()
        shelf = view
        view.wantsLayer = true
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Small panels give all available space back to the terminal. The
        // full Clipboard library remains reachable from the navigation bar.
        let height: CGFloat = showsShelf && shelf != nil && bounds.height >= 360 ? 174 : 0
        let wasHidden = visibleShelfHeight == 0
        visibleShelfHeight = height
        content.frame = NSRect(x: 0, y: height, width: bounds.width,
                               height: max(1, bounds.height - height))
        guard let shelf else { return }
        if !preservesDragSource {
            shelf.isHidden = height == 0
            shelf.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(174, height))
        }
        if wasHidden && height > 0 && window?.isVisible == true {
            shelf.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                shelf.animator().alphaValue = 1
            }
        }
    }
}
