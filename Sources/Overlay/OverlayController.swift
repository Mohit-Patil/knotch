import AppKit

/// A visible tracking surface. Tracking stays local to the owned handle/panel;
/// there is no global mouse monitor or invisible screen-sized hit target.
@MainActor
private final class OverlayTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onPress: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

/// A nonactivating preview that can still become key after deliberate input.
@MainActor
private final class OverlayNativePanel: NSPanel {
    var onPointerDown: (() -> Void)?
    var allowsKey = true
    var anchorsToScreenEdge = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Both the camera silhouette and the plain-display menu-bar handle
        // are anchored to the screen edge, outside AppKit's visible frame.
        anchorsToScreenEdge ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onPointerDown?() }
        super.sendEvent(event)
    }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let triggerPanel: OverlayNativePanel
    private let triggerView: OverlayTrackingView
    private let panelRoot: OverlayTrackingView
    private let triggerLabel = NSTextField(labelWithString: "›_  Knotch")
    private(set) var layout: OverlayLayout?
    var triggerFrame: NSRect { triggerPanel.frame }
    private let content: NSView
    private var compactPanelSize: CGSize?
    private let sessionProvider: () -> (any TerminalSession)?
    private weak var presentedSession: (any TerminalSession)?
    private var hoverTimer: Timer?
    private var exitTimer: Timer?
    private var activationTimer: Timer?
    private var activationGeneration: UInt64 = 0
    private var pendingActivation: UInt64?
    private var priorFrontmostPID: pid_t?
    private var isApplyingPresentation = false
    private var systemDialogDepth = 0
    private let motion = OverlayMotion()
    private var immediatePresentation = false
    var isAnimating: Bool { motion.isAnimating }

    private(set) var state = OverlayState()
    var onPresentationChange: ((OverlayPresentation) -> Void)?
    #if HARNESS_TESTS
    // Controller fixtures supply a complete pointer trace; do not mix in the
    // owner's real pointer when a test window happens to appear underneath it.
    var fixtureControlsTracking = false
    var reduceMotionForFixture: Bool?
    #endif

    private var reduceMotion: Bool {
        #if HARNESS_TESTS
        if let reduceMotionForFixture { return reduceMotionForFixture }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(content: NSView, compactPanelSize: CGSize? = nil,
         sessionProvider: @escaping () -> (any TerminalSession)?) {
        self.content = content
        self.compactPanelSize = compactPanelSize
        self.sessionProvider = sessionProvider
        triggerPanel = OverlayNativePanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 28),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel = OverlayNativePanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        triggerView = OverlayTrackingView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        panelRoot = OverlayTrackingView(frame: NSRect(x: 0, y: 0, width: 960, height: 520))
        super.init()

        configureWindow(triggerPanel)
        triggerPanel.allowsKey = false
        configureWindow(panel)
        panel.delegate = self
        configureTrigger()
        configurePanelContent()

        triggerView.onEnter = { [weak self] in self?.tracked(.pointerEnteredTrigger) }
        triggerView.onExit = { [weak self] in self?.tracked(.pointerExitedTrigger) }
        triggerView.onPress = { [weak self] in self?.activate() }
        panelRoot.onEnter = { [weak self] in self?.tracked(.pointerEnteredPanel) }
        panelRoot.onExit = { [weak self] in self?.tracked(.pointerExitedPanel) }
        triggerPanel.onPointerDown = { [weak self] in self?.activate() }
        (panel as? OverlayNativePanel)?.onPointerDown = { [weak self] in self?.activate() }

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSWindow.didChangeBackingPropertiesNotification,
                                               object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: NSApp)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceResigned),
                                                           name: NSWorkspace.sessionDidResignActiveNotification,
                                                           object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceResigned),
                                                           name: NSWorkspace.willSleepNotification,
                                                           object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil)
        placeOnSelectedScreen()
        triggerPanel.orderFront(nil)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        hoverTimer?.invalidate()
        exitTimer?.invalidate()
        activationTimer?.invalidate()
    }

    func activate() { send(.activate) }

    private func tracked(_ event: OverlayEvent) {
        #if HARNESS_TESTS
        if fixtureControlsTracking { return }
        #endif
        send(event)
    }

    func hide(restoreFocus: Bool = true) {
        let mayRestore = restoreFocus && NSApp.isActive && panel.isKeyWindow
        let pid = mayRestore ? priorFrontmostPID : nil
        send(.hide)
        priorFrontmostPID = nil
        if let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            app.activate()
        }
    }

    func setInteractionLock(_ reason: String, _ locked: Bool) {
        send(locked ? .lockAdded(reason) : .lockRemoved(reason))
    }

    func setHoverEnabled(_ enabled: Bool) { send(.hoverEnabledChanged(enabled)) }

    func setCompactPanelSize(_ size: CGSize?) {
        guard compactPanelSize != size else { return }
        compactPanelSize = size
        placeOnSelectedScreen()
    }

    /// System pickers and alerts must be above the overlay. Restore the
    /// screen-edge level after their modal loop finishes, including cancel.
    func setSystemDialogPresented(_ presented: Bool) {
        systemDialogDepth = max(0, systemDialogDepth + (presented ? 1 : -1))
        updateWindowLevels()
    }

    private func updateWindowLevels() {
        let level: NSWindow.Level = systemDialogDepth > 0 ? .normal : .statusBar
        panel.level = level
        triggerPanel.level = level
    }

    /// The caller changes the supplied content view/session first, then calls this.
    /// It never creates, closes, or replaces a terminal process.
    func sessionChanged() {
        let next = sessionProvider()
        if presentedSession !== next { presentedSession?.setPresented(false) }
        presentedSession = next
        let visible = state.presentation != .collapsed
        next?.setPresented(visible)
        if state.presentation == .interactive && panel.isKeyWindow, let next {
            let accepted = panel.makeFirstResponder(next.view)
            next.setFocused(accepted && panel.firstResponder === next.view)
        } else {
            next?.setFocused(false)
        }
    }

    /// Native tests and owner UI may deliver explicit reducer events here.
    func send(_ event: OverlayEvent) {
        let previousImmediate = immediatePresentation
        if case .screenLocked = event { immediatePresentation = true }
        defer { immediatePresentation = previousImmediate }
        let wasInteractive = state.presentation == .interactive
        let restorePID = NSApp.isActive && panel.isKeyWindow ? priorFrontmostPID : nil
        if case .activate = event {
            if state.presentation == .interactive && !panel.isKeyWindow && pendingActivation == nil {
                priorFrontmostPID = nil
            }
            if (state.presentation != .interactive || !panel.isKeyWindow && pendingActivation == nil),
               let previous = NSWorkspace.shared.frontmostApplication,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                priorFrontmostPID = previous.processIdentifier
            }
        }
        switch event {
        case .focusLost, .screenLocked, .hide:
            cancelPendingActivation()
            priorFrontmostPID = nil
        default:
            break
        }
        let effects = state.send(event, now: ProcessInfo.processInfo.systemUptime)
        apply(effects)
        if case .screenLocked = event {
            // A lock can arrive after the reducer collapsed but while its visual
            // retraction is still running. Always finish that animation now.
            motion.cancel(at: 0)
            renderMotionFrame(0, reducedMotion: reduceMotion)
            finishCollapse()
        }
        if case .timerFired = event, wasInteractive, state.presentation == .collapsed {
            priorFrontmostPID = nil
            // An idle exit timer must never activate an old app after the user switches away.
            if NSApp.isActive, let restorePID,
               let previous = NSRunningApplication(processIdentifier: restorePID), !previous.isTerminated {
                previous.activate()
            }
        }
        if case .activate = event,
           state.presentation == .interactive,
           !panel.isKeyWindow,
           pendingActivation == nil {
            beginActivation()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isApplyingPresentation else { return }
        presentedSession?.setFocused(false)
        send(.focusLost)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if state.presentation == .interactive {
            completeActivation()
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        placeOnSelectedScreen()
    }

    @objc private func workspaceResigned(_ notification: Notification) {
        send(.screenLocked)
    }

    @objc private func motionPreferenceChanged(_ notification: Notification) {
        motion.cancel(at: state.presentation == .collapsed ? 0 : 1)
        renderMotionFrame(motion.value, reducedMotion: reduceMotion)
        if state.presentation == .collapsed { finishCollapse() }
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        guard pendingActivation != nil, state.presentation == .interactive else { return }
        panel.makeKeyAndOrderFront(nil)
        if panel.isKeyWindow { completeActivation() }
    }

    private func configureWindow(_ window: NSPanel) {
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func configureTrigger() {
        triggerView.wantsLayer = true
        triggerView.layer?.backgroundColor = NSColor.black.cgColor
        triggerView.layer?.cornerRadius = 14
        triggerView.layer?.masksToBounds = true
        triggerView.autoresizingMask = [.width, .height]
        triggerPanel.contentView = triggerView
        triggerView.setAccessibilityElement(true)
        triggerView.setAccessibilityRole(.button)
        triggerView.setAccessibilityLabel("Open Knotch terminal")

        let label = triggerLabel
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        triggerView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: triggerView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: triggerView.centerYAnchor)
        ])

    }

    private func configurePanelContent() {
        panelRoot.wantsLayer = true
        panelRoot.layer?.backgroundColor = NSColor.black.cgColor
        panelRoot.layer?.cornerRadius = 18
        panelRoot.layer?.masksToBounds = true
        panelRoot.autoresizingMask = [.width, .height]
        panel.contentView = panelRoot

        content.removeFromSuperview()
        content.frame = panelRoot.bounds
        // The window is a moving clip around this fixed-size terminal host.
        // Never autoresize the terminal for an animation frame.
        content.autoresizingMask = []
        panelRoot.addSubview(content)


    }

    private func apply(_ effects: [OverlayEffect]) {
        for effect in effects {
            switch effect {
            case .scheduleHover(let token, let deadline):
                hoverTimer?.invalidate()
                hoverTimer = scheduledTimer(token: token, deadline: deadline)
            case .scheduleExit(let token, let deadline):
                exitTimer?.invalidate()
                exitTimer = scheduledTimer(token: token, deadline: deadline)
            case .cancelTimers:
                hoverTimer?.invalidate()
                exitTimer?.invalidate()
                hoverTimer = nil
                exitTimer = nil
            case .presentationChanged(let presentation):
                present(presentation)
                onPresentationChange?(presentation)
            case .requestFocus:
                beginActivation()
            case .releaseFocus:
                presentedSession?.setFocused(false)
            }
        }
    }

    private func scheduledTimer(token: UInt64, deadline: Double) -> Timer {
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        return Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.send(.timerFired(token)) }
        }
    }

    private func beginActivation() {
        activationGeneration &+= 1
        let token = activationGeneration
        pendingActivation = token
        activationTimer?.invalidate()
        activationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.activationTimedOut(token) }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if panel.isKeyWindow { completeActivation() }
    }

    private func completeActivation() {
        guard state.presentation == .interactive && panel.isKeyWindow else { return }
        cancelPendingActivation()
        guard let session = sessionProvider() else { return }
        let accepted = panel.makeFirstResponder(session.view)
        session.setFocused(accepted && panel.firstResponder === session.view)
    }

    private func activationTimedOut(_ token: UInt64) {
        guard pendingActivation == token else { return }
        if panel.isKeyWindow {
            completeActivation()
        } else {
            send(.focusLost)
        }
    }

    private func cancelPendingActivation() {
        pendingActivation = nil
        activationTimer?.invalidate()
        activationTimer = nil
    }

    private func present(_ presentation: OverlayPresentation) {
        isApplyingPresentation = true
        defer { isApplyingPresentation = false }
        updateTriggerAppearance()
        switch presentation {
        case .collapsed:
            cancelPendingActivation()
            presentedSession?.setFocused(false)
            panel.makeFirstResponder(nil)
            panel.resignKey()
            panel.ignoresMouseEvents = true
            animatePresentation(expanded: false)
            triggerPanel.orderFront(nil)
        case .preview:
            sessionChanged()
            presentedSession?.setFocused(false)
            animatePresentation(expanded: true)
            triggerPanel.orderFront(nil)
        case .interactive:
            sessionChanged()
            animatePresentation(expanded: true)
            triggerPanel.orderFront(nil)
        }
    }

    private func animatePresentation(expanded: Bool) {
        let reduced = reduceMotion
        if expanded {
            panel.ignoresMouseEvents = false
            if !panel.isVisible {
                renderMotionFrame(0, reducedMotion: reduced)
                panel.orderFront(nil)
            }
        }
        motion.move(to: expanded ? 1 : 0, in: panelRoot, reducedMotion: reduced,
                    animated: !immediatePresentation && (expanded || panel.isVisible),
                    frame: { [weak self] value, reduced in
                        self?.renderMotionFrame(value, reducedMotion: reduced)
                    }, completion: { [weak self] in
                        guard let self, self.state.presentation == .collapsed else { return }
                        self.finishCollapse()
                    })
    }

    private func finishCollapse() {
        let previous = isApplyingPresentation
        isApplyingPresentation = true
        defer { isApplyingPresentation = previous }
        panel.orderOut(nil)
        presentedSession?.setPresented(false)
        panel.alphaValue = 1
    }

    private func renderMotionFrame(_ value: Double, reducedMotion: Bool) {
        guard let layout else { return }
        let rest = layout.panelFrame
        let progress = reducedMotion ? 1 : max(0, min(1.08, value))
        let widthLimit = 2 * min(rest.midX - layout.usableFrame.minX,
                                 layout.usableFrame.maxX - rest.midX)
        let width = min(widthLimit, layout.triggerFrame.width + (rest.width - layout.triggerFrame.width) * progress)
        let height = min(rest.maxY - layout.usableFrame.minY, 8 + (rest.height - 8) * progress)
        let frame = NSRect(x: rest.midX - max(1, width) / 2, y: rest.maxY - max(1, height),
                           width: max(1, width), height: max(1, height))
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        content.frame = NSRect(x: (panelRoot.bounds.width - rest.width) / 2,
                               y: panelRoot.bounds.height - rest.height,
                               width: rest.width, height: rest.height)
        let visible = max(0, min(1, value))
        panel.alphaValue = reducedMotion ? visible : 1
        content.alphaValue = reducedMotion ? 1 : max(0, min(1, (visible - 0.12) / 0.55))
        panelRoot.layer?.cornerRadius = 10 + 8 * visible
    }

    private func updateTriggerAppearance() {
        let notched = layout?.notchFrame != nil
        triggerLabel.isHidden = notched
        triggerView.layer?.cornerRadius = notched ? 10 : 14
        triggerView.layer?.maskedCorners = notched
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    private func placeOnSelectedScreen() {
        guard let screen = selectedScreen() else { return }
        let displayID = Self.displayID(for: screen)
        if state.targetDisplayID != displayID { send(.displayChanged(displayID)) }
        var geometry = DisplayGeometry(screenFrame: screen.frame,
                                       visibleFrame: screen.visibleFrame,
                                       safeAreaTop: screen.safeAreaInsets.top,
                                       auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                       auxiliaryTopRight: screen.auxiliaryTopRightArea,
                                       backingScale: screen.backingScaleFactor)
        geometry.panelGap = 0
        geometry.compactPanelSize = compactPanelSize
        let layout = geometry.layout()
        if let old = self.layout, old.panelFrame == layout.panelFrame,
           old.triggerFrame == layout.triggerFrame, old.backingScale == layout.backingScale { return }
        self.layout = layout
        let notched = layout.notchFrame != nil
        (panel as? OverlayNativePanel)?.anchorsToScreenEdge = true
        updateWindowLevels()
        panelRoot.layer?.maskedCorners = notched
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        triggerPanel.anchorsToScreenEdge = true
        triggerPanel.setFrame(layout.triggerFrame, display: true)
        motion.cancel(at: state.presentation == .collapsed ? 0 : 1)
        renderMotionFrame(motion.value, reducedMotion: reduceMotion)
        if state.presentation == .collapsed { finishCollapse() }
        updateTriggerAppearance()
    }

    private func selectedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let targetID = state.targetDisplayID,
           let target = screens.first(where: { Self.displayID(for: $0) == targetID }) {
            return target
        }
        return screens.first(where: {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }) ?? NSScreen.main ?? screens.first
    }

    private static func displayID(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue
    }
}
