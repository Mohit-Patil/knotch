import CoreGraphics

@main
struct ModelTests {
    static func main() {
        testMotion()
        testHoverAndStaleTimers()
        testExitGraceAndLocks()
        testActivationFocusPinAndHide()
        testInteractiveExitAndTypingGrace()
        testInteractiveLocksAndKeyboardOnlyAccess()
        testDialogReactivationRetainsExit()
        testDisplayAndNotifications()
        testGeometry()
        testRandomizedTransitions()
        print("Model tests passed")
    }

    static func testMotion() {
        let opening = OverlayMotionCurve(from: 0, to: 1)
        let samples = (0...580).map { opening.sample(at: Double($0) / 1000).value }
        expect(samples.max()! > 1.01 && samples.max()! < 1.08, "gentle bounded opening bounce")
        expect(opening.sample(at: opening.duration).value == 1, "opening settles exactly")
        let interrupted = opening.sample(at: 0.15)
        let closing = OverlayMotionCurve(from: interrupted.value, to: 0, initialVelocity: interrupted.velocity)
        expect(abs(closing.sample(at: 0).value - interrupted.value) < 0.00001,
               "retarget preserves position")
        expect(abs(closing.sample(at: 0).velocity - interrupted.velocity) < 0.00001,
               "retarget preserves velocity")
        expect(closing.sample(at: closing.duration).value == 0, "closing settles exactly")
        let reduced = OverlayMotionCurve(from: 0, to: 1, reducedMotion: true)
        let fade = (0...120).map { reduced.sample(at: Double($0) / 1000).value }
        expect(zip(fade, fade.dropFirst()).allSatisfy { $0 <= $1 }, "Reduce Motion is monotonic")
    }

    static func testHoverAndStaleTimers() {
        var state = OverlayState()
        let first = hoverToken(state.send(.pointerEnteredTrigger, now: 10))
        expect(state.send(.pointerEnteredTrigger, now: 10.02).isEmpty,
               "duplicate tracking entry must not restart dwell")
        expect(state.presentation == .collapsed, "pointer entry must not reveal immediately")
        state.send(.pointerExitedTrigger, now: 10.05)
        state.send(.timerFired(first), now: 11)
        expect(state.presentation == .collapsed, "cancelled dwell must stay collapsed")
        let second = hoverToken(state.send(.pointerEnteredTrigger, now: 12))
        expect(second != first, "timers need unique generations")
        state.send(.timerFired(second), now: 12.17)
        expect(state.presentation == .collapsed, "early timer must not reveal")
        state.send(.timerFired(first), now: 13)
        expect(state.presentation == .collapsed, "stale dwell must not reveal")
        let effects = state.send(.timerFired(second), now: 13)
        expect(state.presentation == .preview, "qualified dwell must reveal preview")
        expect(!state.ownsFocus && !effects.contains(.requestFocus), "hover must never request focus")

        state.send(.hide, now: 14)
        state.send(.hoverEnabledChanged(false), now: 15)
        expect(state.send(.pointerEnteredTrigger, now: 16).isEmpty, "disabled hover must not arm")
        expect(state.presentation == .collapsed, "disabled hover must stay collapsed")
    }

    static func testExitGraceAndLocks() {
        var state = OverlayState()
        reveal(&state, at: 0)
        let first = exitToken(state.send(.pointerExitedTrigger, now: 1))
        state.send(.pointerEnteredPanel, now: 1.1)
        state.send(.timerFired(first), now: 2)
        expect(state.presentation == .preview, "panel entry cancels exit")
        let second = exitToken(state.send(.pointerExitedPanel, now: 2))
        state.send(.lockAdded("ime"), now: 2.1)
        state.send(.timerFired(second), now: 3)
        expect(state.presentation == .preview, "IME lock prevents collapse")
        state.send(.lockAdded("selection"), now: 3)
        state.send(.lockAdded("modal"), now: 3)
        state.send(.lockRemoved("ime"), now: 3)
        state.send(.lockRemoved("selection"), now: 3)
        expect(state.presentation == .preview, "remaining modal lock holds preview")
        let third = exitToken(state.send(.lockRemoved("modal"), now: 4))
        state.send(.timerFired(third), now: 4.349)
        expect(state.presentation == .preview, "exit grace must be observed")
        state.send(.timerFired(third), now: 4.350)
        expect(state.presentation == .collapsed, "exit grace collapses when unlocked")
    }

    static func testActivationFocusPinAndHide() {
        var state = OverlayState()
        let effects = state.send(.activate, now: 0)
        expect(state.presentation == .interactive && state.ownsFocus, "activation enters interactive")
        expect(effects.contains(.requestFocus), "activation must request focus")
        expect(state.send(.pointerExitedTrigger, now: 1).isEmpty
               && state.send(.pointerExitedPanel, now: 1).isEmpty,
               "shortcut opening without pointer entry has no exit timer")
        expect(state.presentation == .interactive, "keyboard-only opening stays interactive")
        state.send(.focusLost, now: 2)
        expect(state.presentation == .collapsed && !state.ownsFocus, "unpin focus loss collapses")

        state.send(.pinChanged(true), now: 3)
        expect(state.presentation == .preview, "pin shows panel")
        state.send(.activate, now: 4)
        state.send(.focusLost, now: 5)
        expect(state.presentation == .preview && !state.ownsFocus, "pinned focus loss remains visible and unfocused")
        let hideEffects = state.send(.hide, now: 6)
        expect(state.presentation == .collapsed, "explicit hide overrides pin")
        expect(!hideEffects.contains(.requestFocus), "hide must not restore focus itself")
        state.send(.activate, now: 7)
        let focusedHide = state.send(.hide, now: 8)
        expect(focusedHide.contains(.releaseFocus), "hide releases owned focus")
        state.send(.lockAdded("menu"), now: 9)
        state.send(.activate, now: 10)
        state.send(.focusLost, now: 11)
        expect(state.presentation == .preview, "menu lock holds presentation on focus loss")
    }

    static func testInteractiveExitAndTypingGrace() {
        var state = OverlayState()
        state.send(.activate, now: 0)
        state.send(.pointerEnteredPanel, now: 0.1)
        let first = exitToken(state.send(.pointerExitedPanel, now: 1))
        state.send(.timerFired(first), now: 1.34)
        expect(state.presentation == .interactive, "interactive exit waits for grace")
        let collapse = state.send(.timerFired(first), now: 1.36)
        expect(state.presentation == .collapsed && !state.ownsFocus,
               "interactive pointer exit minimises after grace")
        expect(collapse.contains(.releaseFocus), "timed collapse releases terminal focus")

        state.send(.activate, now: 10)
        state.send(.pointerEnteredPanel, now: 10.1)
        state.send(.terminalInput, now: 10.2)
        let exit = state.send(.pointerExitedPanel, now: 10.3)
        let second = exitToken(exit)
        expect(exitDeadline(exit) >= 11.7, "recent typing extends exit past ordinary grace")
        state.send(.timerFired(second), now: 10.7)
        expect(state.presentation == .interactive, "recent typing holds interactive panel")
        let renewed = state.send(.terminalInput, now: 11)
        let third = exitToken(renewed)
        expect(third != second && exitDeadline(renewed) >= 12.5,
               "each input renews inactivity deadline and timer token")
        state.send(.timerFired(second), now: 12)
        expect(state.presentation == .interactive, "stale timer cannot collapse during typing")
        state.send(.timerFired(third), now: 12.49)
        expect(state.presentation == .interactive, "typing grace persists until deadline")
        let final = state.send(.timerFired(third), now: 12.51)
        expect(state.presentation == .collapsed && final.contains(.releaseFocus),
               "interactive panel minimises after typing inactivity")
    }

    static func testInteractiveLocksAndKeyboardOnlyAccess() {
        var state = OverlayState()
        state.send(.activate, now: 0)
        expect(state.send(.terminalInput, now: 0.2).isEmpty,
               "typing event alone neither changes focus nor presentation")
        state.send(.timerFired(999), now: 5)
        expect(state.presentation == .interactive, "shortcut access stays open without actual pointer exit")

        state.send(.pointerEnteredPanel, now: 6)
        state.send(.lockAdded("selection"), now: 6.1)
        expect(state.send(.pointerExitedPanel, now: 6.2).isEmpty,
               "selection lock suppresses pointer exit schedule")
        state.send(.terminalInput, now: 6.3)
        let unlocked = state.send(.lockRemoved("selection"), now: 6.4)
        let token = exitToken(unlocked)
        expect(exitDeadline(unlocked) >= 7.8, "unlock retains exit intent and recent typing grace")
        state.send(.pointerEnteredTrigger, now: 6.5)
        state.send(.timerFired(token), now: 8)
        expect(state.presentation == .interactive, "reentry invalidates lock-release timer")
        state.send(.pinChanged(true), now: 8.1)
        expect(state.send(.pointerExitedTrigger, now: 8.2).isEmpty,
               "pin blocks interactive auto-collapse")
        let unpinned = state.send(.pinChanged(false), now: 8.3)
        let unpinToken = exitToken(unpinned)
        state.send(.timerFired(unpinToken), now: 8.66)
        expect(state.presentation == .collapsed, "unpin honors recorded pointer exit")
        expect(state.send(.terminalInput, now: 9).isEmpty
               && state.presentation == .collapsed && !state.ownsFocus,
               "input notification cannot reopen a hidden panel")
    }

    static func testDialogReactivationRetainsExit() {
        var state = OverlayState()
        state.send(.activate, now: 0)
        state.send(.pointerEnteredPanel, now: 0.1)
        state.send(.lockAdded("dialog"), now: 0.2)
        expect(state.send(.pointerExitedPanel, now: 0.3).isEmpty,
               "pointer exit during dialog is held without a timer")
        state.send(.terminalInput, now: 0.4)
        state.send(.focusLost, now: 0.5)
        expect(state.presentation == .preview, "dialog holds preview after focus moves")
        state.send(.activate, now: 1.0)
        expect(state.presentation == .interactive, "opening selected directory can reactivate under dialog lock")
        let unlocked = state.send(.lockRemoved("dialog"), now: 1.1)
        let token = exitToken(unlocked)
        expect(exitDeadline(unlocked) >= 1.9,
               "reactivation preserves pointer exit and last-input grace until unlock")
        state.send(.timerFired(token), now: 1.89)
        expect(state.presentation == .interactive, "last-input grace still holds after dialog")
        let collapsed = state.send(.timerFired(token), now: 1.91)
        expect(state.presentation == .collapsed && collapsed.contains(.releaseFocus),
               "dialog release eventually minimises and releases focus")

        var shortcut = OverlayState()
        shortcut.send(.lockAdded("dialog"), now: 0)
        shortcut.send(.activate, now: 0.1)
        expect(shortcut.send(.lockRemoved("dialog"), now: 0.2).isEmpty,
               "fresh shortcut under lock has no invented pointer exit")
        shortcut.send(.timerFired(999), now: 2)
        expect(shortcut.presentation == .interactive,
               "keyboard-only activation remains open after lock release")
    }

    static func testDisplayAndNotifications() {
        var state = OverlayState()
        let hover = hoverToken(state.send(.pointerEnteredTrigger, now: 0))
        state.send(.displayChanged("external"), now: 0.1)
        state.send(.timerFired(hover), now: 1)
        expect(state.targetDisplayID == "external" && state.presentation == .collapsed,
               "display change invalidates hover")
        state.send(.notificationReceived, now: 2)
        expect(state.presentation == .collapsed && !state.ownsFocus, "notification cannot reveal or focus")
        state.send(.activate, now: 3)
        state.send(.displayChanged(nil), now: 4)
        expect(state.presentation == .interactive && state.targetDisplayID == nil,
               "interactive panel survives display reassignment")
        state.send(.screenLocked, now: 5)
        expect(state.presentation == .collapsed && !state.ownsFocus, "screen lock hides sensitive content")
    }

    static func testGeometry() {
        let screen = CGRect(x: -1920, y: -80, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -80, width: 1920, height: 1040)
        var geometry = DisplayGeometry(screenFrame: screen, visibleFrame: visible,
                                       safeAreaTop: 34,
                                       auxiliaryTopLeft: CGRect(x: -1920, y: 966, width: 810, height: 34),
                                       auxiliaryTopRight: CGRect(x: -810, y: 966, width: 810, height: 34),
                                       backingScale: 2)
        let notch = geometry.layout()
        expect(screen.contains(notch.triggerFrame) && screen.contains(notch.panelFrame),
               "negative-origin silhouette and body stay on screen")
        expect(notch.notchFrame == CGRect(x: -1110, y: 966, width: 300, height: 34),
               "negative-origin auxiliary areas identify the physical cutout")
        expect(near(notch.triggerFrame.maxY, screen.maxY)
               && notch.triggerFrame.minY < notch.panelFrame.maxY,
               "silhouette reaches the screen edge and joins the panel lip")
        expect(notch.backingPixels(for: CGSize(width: 100, height: 50)) == CGSize(width: 200, height: 100),
               "2x backing conversion")

        var liveGeometry = DisplayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
                                           visibleFrame: CGRect(x: 63, y: 0, width: 1647, height: 1073),
                                           safeAreaTop: 38,
                                           auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 751, height: 38),
                                           auxiliaryTopRight: CGRect(x: 960, y: 1074, width: 750, height: 38),
                                           backingScale: 2)
        let live = liveGeometry.layout()
        expect(live.notchFrame == CGRect(x: 751, y: 1074, width: 209, height: 38),
               "live screen cutout coordinates must be preserved")
        expect(live.triggerFrame == CGRect(x: 743, y: 1072, width: 225, height: 40),
               "trigger wraps cutout with 8 pt wings and a 2 pt lip")
        expect(near(live.panelFrame.maxY, 1112)
               && near(live.panelFrame.midX, 855.5),
               "panel starts at actual screen top and cutout center")
        expect(live.triggerFrame.intersects(live.panelFrame),
               "regression: panel and physical-notch trigger must not detach")
        liveGeometry.visibleFrame = liveGeometry.screenFrame
        let notchWithHiddenMenu = liveGeometry.layout()
        expect(near(notchWithHiddenMenu.panelFrame.maxY, 1112),
               "auto-hidden menu does not move the screen-edge panel")

        geometry.auxiliaryTopLeft = nil
        geometry.auxiliaryTopRight = nil
        geometry.safeAreaTop = 0
        geometry.backingScale = 1
        let plain = geometry.layout()
        expect(plain.notchFrame == nil, "plain display has no inferred cutout")
        expect(near(plain.triggerFrame.maxY, screen.maxY)
               && plain.triggerFrame.minY >= visible.maxY
               && near(plain.panelFrame.maxY, screen.maxY)
               && screen.contains(plain.panelFrame),
               "plain-display handle occupies menu-bar band and body joins screen edge")
        expect(near(plain.triggerFrame.midX, screen.midX), "plain display uses top center")
        expect(plain.backingPixels(for: CGSize(width: 100, height: 50)) == CGSize(width: 100, height: 50),
               "1x backing conversion")

        geometry.screenFrame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        geometry.visibleFrame = CGRect(x: 63, y: 0, width: 3777, height: 2130)
        let external = geometry.layout()
        expect(external.triggerFrame == CGRect(x: 1840, y: 2132, width: 160, height: 28)
               && external.panelFrame == CGRect(x: 1280, y: 1440, width: 1280, height: 720),
               "3840x2160 external display uses menu-bar handle and larger fitted terminal")
        geometry.compactPanelSize = CGSize(width: 600, height: 240)
        let emptyExternal = geometry.layout()
        expect(emptyExternal.panelFrame == CGRect(x: 1620, y: 1920, width: 600, height: 240),
               "empty state occupies a compact screen-edge panel")
        geometry.compactPanelSize = CGSize(width: 640, height: 320)
        let settingsExternal = geometry.layout()
        expect(settingsExternal.panelFrame == CGRect(x: 1600, y: 1840, width: 640, height: 320),
               "settings tab gets a compact panel that fits its controls")
        geometry.compactPanelSize = nil
        geometry.userPanelSize = CGSize(width: 1100, height: 610)
        expect(geometry.layout().panelFrame == CGRect(x: 1370, y: 1550, width: 1100, height: 610),
               "saved terminal size overrides the adaptive display default")
        geometry.userPanelSize = nil

        geometry.screenFrame = screen
        geometry.visibleFrame = visible

        geometry.visibleFrame = CGRect(x: -1920, y: -80, width: 1920, height: 1080)
        let autoHiddenMenu = geometry.layout()
        expect(near(autoHiddenMenu.triggerFrame.maxY, screen.maxY)
               && near(autoHiddenMenu.panelFrame.maxY, screen.maxY),
               "auto-hidden menu keeps the plain-display handle at screen edge")

        geometry.auxiliaryTopLeft = CGRect(x: -1920, y: 900, width: 810, height: 34)
        geometry.auxiliaryTopRight = CGRect(x: -810, y: 966, width: 810, height: 34)
        expect(geometry.layout().notchFrame == nil, "inconsistent auxiliary areas fall back safely")
        geometry.auxiliaryTopLeft = nil
        geometry.auxiliaryTopRight = nil

        geometry.screenFrame = CGRect(x: -400, y: 200, width: 290, height: 130)
        geometry.visibleFrame = CGRect(x: -400, y: 200, width: 290, height: 130)
        geometry.safeAreaTop = 40
        let tiny = geometry.layout()
        expect(tiny.panelFrame.width > 0 && tiny.panelFrame.height > 0, "tiny panel remains positive")
        expect(geometry.visibleFrame.contains(tiny.triggerFrame)
               && geometry.visibleFrame.contains(tiny.panelFrame), "tiny frames remain visible")

        let start = CGSize(width: 800, height: 500)
        let usable = CGSize(width: 1200, height: 900)
        expect(PanelResizeHandle.bottom.size(from: start,
                                             movement: CGPoint(x: 200, y: -70), usable: usable)
               == CGSize(width: 800, height: 570), "bottom edge only changes height")
        expect(PanelResizeHandle.lowerRight.size(from: start,
                                                 movement: CGPoint(x: 50, y: -40), usable: usable)
               == CGSize(width: 900, height: 540), "lower-right corner changes width and height")
        expect(PanelResizeHandle.lowerLeft.size(from: start,
                                                movement: CGPoint(x: -60, y: 30), usable: usable)
               == CGSize(width: 920, height: 470), "lower-left corner changes width and height")
        expect(PanelResizeHandle.lowerRight.size(from: start,
                                                 movement: CGPoint(x: 500, y: -900), usable: usable)
               == usable, "drag clamps to the selected screen")
    }

    static func testRandomizedTransitions() {
        var state = OverlayState()
        var random: UInt64 = 0x5eed1234
        var now = 0.0
        var tokens: [UInt64] = []
        for _ in 0..<10_000 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            now += 0.017
            let event: OverlayEvent
            switch random % 16 {
            case 0: event = .pointerEnteredTrigger
            case 1: event = .pointerExitedTrigger
            case 2: event = .pointerEnteredPanel
            case 3: event = .pointerExitedPanel
            case 4: event = .activate
            case 5: event = .hide
            case 6: event = .focusLost
            case 7: event = .pinChanged((random & 16) != 0)
            case 8: event = .hoverEnabledChanged((random & 32) != 0)
            case 9: event = .lockAdded("modal")
            case 10: event = .lockRemoved("modal")
            case 11: event = .displayChanged((random & 64) != 0 ? "A" : "B")
            case 12: event = .notificationReceived
            case 13: event = .screenLocked
            case 14: event = .terminalInput
            default: event = .timerFired(tokens.isEmpty ? 0 : tokens[Int(random % UInt64(tokens.count))])
            }
            let before = state.presentation
            let effects = state.send(event, now: now)
            for effect in effects {
                switch effect {
                case .scheduleHover(let token, _), .scheduleExit(let token, _): tokens.append(token)
                default: break
                }
            }
            expect(state.presentation != .interactive || state.ownsFocus,
                   "interactive presentation must own focus")
            expect(state.presentation != .collapsed || !state.ownsFocus,
                   "collapsed presentation must not own focus")
            if case .notificationReceived = event {
                expect(state.presentation == before && !effects.contains(.requestFocus),
                       "notification cannot change presentation or focus")
            }
            if case .terminalInput = event {
                expect(state.presentation == before && !effects.contains(.requestFocus)
                       && !effects.contains(.releaseFocus),
                       "terminal input cannot open, close, or change focus")
            }
        }
    }

    static func reveal(_ state: inout OverlayState, at time: Double) {
        let token = hoverToken(state.send(.pointerEnteredTrigger, now: time))
        state.send(.timerFired(token), now: time + state.hoverDwell)
        expect(state.presentation == .preview, "test setup must reveal preview")
    }

    static func hoverToken(_ effects: [OverlayEffect]) -> UInt64 {
        for effect in effects {
            if case .scheduleHover(let token, _) = effect { return token }
        }
        fatalError("expected hover timer")
    }

    static func exitToken(_ effects: [OverlayEffect]) -> UInt64 {
        for effect in effects {
            if case .scheduleExit(let token, _) = effect { return token }
        }
        fatalError("expected exit timer")
    }

    static func exitDeadline(_ effects: [OverlayEffect]) -> Double {
        for effect in effects {
            if case .scheduleExit(_, let deadline) = effect { return deadline }
        }
        fatalError("expected exit deadline")
    }

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
