import CoreGraphics

@main
struct ModelTests {
    static func main() {
        testHoverAndStaleTimers()
        testExitGraceAndLocks()
        testActivationFocusPinAndHide()
        testDisplayAndNotifications()
        testGeometry()
        testRandomizedTransitions()
        print("Model tests passed")
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
        state.send(.pointerExitedTrigger, now: 1)
        state.send(.pointerExitedPanel, now: 1)
        expect(state.presentation == .interactive, "pointer exit cannot collapse interactive")
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
        expect(visible.contains(notch.triggerFrame) && visible.contains(notch.panelFrame),
               "negative-origin frames must stay visible")
        expect(notch.panelFrame.maxY <= notch.triggerFrame.minY, "panel belongs below trigger")
        expect(notch.backingPixels(for: CGSize(width: 100, height: 50)) == CGSize(width: 200, height: 100),
               "2x backing conversion")

        geometry.auxiliaryTopLeft = nil
        geometry.auxiliaryTopRight = nil
        geometry.safeAreaTop = 0
        geometry.backingScale = 1
        let plain = geometry.layout()
        expect(near(plain.triggerFrame.midX, screen.midX), "plain display uses top center")
        expect(plain.backingPixels(for: CGSize(width: 100, height: 50)) == CGSize(width: 100, height: 50),
               "1x backing conversion")

        geometry.visibleFrame = CGRect(x: -1920, y: -80, width: 1920, height: 1080)
        let autoHiddenMenu = geometry.layout()
        expect(autoHiddenMenu.triggerFrame.maxY > plain.triggerFrame.maxY,
               "auto-hidden menu bar makes top space available")

        geometry.screenFrame = CGRect(x: -400, y: 200, width: 290, height: 130)
        geometry.visibleFrame = CGRect(x: -400, y: 200, width: 290, height: 130)
        geometry.safeAreaTop = 40
        let tiny = geometry.layout()
        expect(tiny.panelFrame.width > 0 && tiny.panelFrame.height > 0, "tiny panel remains positive")
        expect(geometry.visibleFrame.contains(tiny.triggerFrame)
               && geometry.visibleFrame.contains(tiny.panelFrame), "tiny frames remain visible")
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
            switch random % 15 {
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
            if case .pointerExitedPanel = event, before == .interactive {
                expect(state.presentation == .interactive, "pointer exit cannot close interactive")
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

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
