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
        // Only the small hardware-aligned cap may enter the menu-bar region.
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
    private let previewHint: NSTextField
    private let triggerLabel = NSTextField(labelWithString: "›_  Knotch")
    private let triggerGrip = NSView()
    private(set) var layout: OverlayLayout?
    var triggerFrame: NSRect { triggerPanel.frame }
    private let content: NSView
    private let sessionProvider: () -> (any TerminalSession)?
    private weak var presentedSession: (any TerminalSession)?
    private var hoverTimer: Timer?
    private var exitTimer: Timer?
    private var activationTimer: Timer?
    private var activationGeneration: UInt64 = 0
    private var pendingActivation: UInt64?
    private var priorFrontmostPID: pid_t?
    private var isApplyingPresentation = false

    private(set) var state = OverlayState()
    var onPresentationChange: ((OverlayPresentation) -> Void)?
    #if HARNESS_TESTS
    // Controller fixtures supply a complete pointer trace; do not mix in the
    // owner's real pointer when a test window happens to appear underneath it.
    var fixtureControlsTracking = false
    #endif

    init(content: NSView, sessionProvider: @escaping () -> (any TerminalSession)?) {
        self.content = content
        self.sessionProvider = sessionProvider
        triggerPanel = OverlayNativePanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 28),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel = OverlayNativePanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        triggerView = OverlayTrackingView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        panelRoot = OverlayTrackingView(frame: NSRect(x: 0, y: 0, width: 960, height: 520))
        previewHint = NSTextField(labelWithString: "Click to type")
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
        triggerGrip.wantsLayer = true
        triggerGrip.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
        triggerGrip.layer?.cornerRadius = 1.5
        triggerGrip.translatesAutoresizingMaskIntoConstraints = false
        triggerView.addSubview(triggerGrip)
        NSLayoutConstraint.activate([
            triggerGrip.centerXAnchor.constraint(equalTo: triggerView.centerXAnchor),
            triggerGrip.bottomAnchor.constraint(equalTo: triggerView.bottomAnchor, constant: -2),
            triggerGrip.widthAnchor.constraint(equalToConstant: 32),
            triggerGrip.heightAnchor.constraint(equalToConstant: 3)
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
        content.autoresizingMask = [.width, .height]
        panelRoot.addSubview(content)

        previewHint.font = .systemFont(ofSize: 11, weight: .medium)
        previewHint.textColor = .white
        previewHint.alignment = .center
        previewHint.wantsLayer = true
        previewHint.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.95).cgColor
        previewHint.layer?.cornerRadius = 8
        previewHint.frame = NSRect(x: panelRoot.bounds.maxX - 124,
                                   y: panelRoot.bounds.maxY - 28,
                                   width: 112, height: 20)
        previewHint.autoresizingMask = [.minXMargin, .minYMargin]
        previewHint.isHidden = true
        panelRoot.addSubview(previewHint)
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
            previewHint.isHidden = true
            presentedSession?.setFocused(false)
            presentedSession?.setPresented(false)
            panel.orderOut(nil)
            triggerPanel.orderFront(nil)
        case .preview:
            previewHint.isHidden = false
            sessionChanged()
            presentedSession?.setFocused(false)
            panel.orderFront(nil)
            triggerPanel.orderFront(nil)
        case .interactive:
            previewHint.isHidden = true
            sessionChanged()
            panel.orderFront(nil)
            triggerPanel.orderFront(nil)
        }
    }

    private func updateTriggerAppearance() {
        let notched = layout?.notchFrame != nil
        triggerLabel.isHidden = notched
        triggerGrip.isHidden = !notched || state.presentation != .collapsed
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
        let layout = geometry.layout()
        self.layout = layout
        triggerPanel.anchorsToScreenEdge = layout.notchFrame != nil
        triggerPanel.level = layout.notchFrame != nil ? .statusBar : .floating
        triggerPanel.setFrame(layout.triggerFrame, display: true)
        panel.setFrame(layout.panelFrame, display: true)
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
