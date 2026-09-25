/// Presentation is independent of the lifetime of any terminal session.
enum OverlayPresentation: Equatable {
    case collapsed
    case preview
    case interactive
}

enum OverlayEvent {
    case pointerEnteredTrigger
    case pointerExitedTrigger
    case pointerEnteredPanel
    case pointerExitedPanel
    case timerFired(UInt64)
    case activate
    case hide
    case focusLost
    case pinChanged(Bool)
    case hoverEnabledChanged(Bool)
    case lockAdded(String)
    case lockRemoved(String)
    case displayChanged(String?)
    case selectedSessionChanged(String?)
    case enlargedChanged(Bool)
    case notificationReceived
    case screenLocked
}

enum OverlayEffect: Equatable {
    case scheduleHover(token: UInt64, deadline: Double)
    case scheduleExit(token: UInt64, deadline: Double)
    case cancelTimers
    case presentationChanged(OverlayPresentation)
    case requestFocus
    case releaseFocus
}

/// `send` has no clock or UI dependencies. The caller owns the monotonic clock and
/// delivers timer callbacks using the token in a scheduling effect.
struct OverlayState {
    var presentation: OverlayPresentation = .collapsed
    var isPinned = false
    var isEnlarged = false
    var hoverEnabled = true
    var interactionLocks: Set<String> = []
    var selectedSessionID: String?
    var targetDisplayID: String?
    var hoverDwell = 0.180
    var exitGrace = 0.350

    private(set) var pointerInTrigger = false
    private(set) var pointerInPanel = false
    private(set) var ownsFocus = false

    private struct PendingTimer {
        let token: UInt64
        let deadline: Double
    }

    private var nextToken: UInt64 = 0
    private var pendingHover: PendingTimer?
    private var pendingExit: PendingTimer?

    @discardableResult
    mutating func send(_ event: OverlayEvent, now: Double) -> [OverlayEffect] {
        var effects: [OverlayEffect] = []
        switch event {
        case .pointerEnteredTrigger:
            guard !pointerInTrigger else { return effects }
            pointerInTrigger = true
            cancelPending(&effects)
            if presentation == .collapsed && hoverEnabled {
                armHover(now: now, &effects)
            }

        case .pointerExitedTrigger:
            guard pointerInTrigger else { return effects }
            pointerInTrigger = false
            if presentation == .collapsed {
                cancelPending(&effects)
            } else {
                armExitIfEligible(now: now, &effects)
            }

        case .pointerEnteredPanel:
            guard !pointerInPanel else { return effects }
            pointerInPanel = true
            cancelPending(&effects)

        case .pointerExitedPanel:
            guard pointerInPanel else { return effects }
            pointerInPanel = false
            armExitIfEligible(now: now, &effects)

        case .timerFired(let token):
            if let timer = pendingHover, timer.token == token, now >= timer.deadline {
                pendingHover = nil
                if presentation == .collapsed && hoverEnabled && pointerInTrigger {
                    changePresentation(.preview, &effects)
                }
            } else if let timer = pendingExit, timer.token == token, now >= timer.deadline {
                pendingExit = nil
                if presentation == .preview && !isPinned && interactionLocks.isEmpty
                    && !pointerInTrigger && !pointerInPanel {
                    changePresentation(.collapsed, &effects)
                }
            }

        case .activate:
            cancelPending(&effects)
            if presentation != .interactive || !ownsFocus {
                ownsFocus = true
                changePresentation(.interactive, &effects)
                effects.append(.requestFocus)
            }

        case .hide, .screenLocked:
            cancelPending(&effects)
            pointerInTrigger = false
            pointerInPanel = false
            if ownsFocus {
                ownsFocus = false
                effects.append(.releaseFocus)
            }
            changePresentation(.collapsed, &effects)

        case .focusLost:
            cancelPending(&effects)
            ownsFocus = false
            if presentation == .interactive {
                changePresentation(isPinned || !interactionLocks.isEmpty ? .preview : .collapsed, &effects)
            }

        case .pinChanged(let pinned):
            isPinned = pinned
            cancelPending(&effects)
            if pinned && presentation == .collapsed {
                changePresentation(.preview, &effects)
            } else if !pinned {
                armExitIfEligible(now: now, &effects)
            }

        case .hoverEnabledChanged(let enabled):
            hoverEnabled = enabled
            cancelPending(&effects)
            if enabled && presentation == .collapsed && pointerInTrigger {
                armHover(now: now, &effects)
            }

        case .lockAdded(let reason):
            interactionLocks.insert(reason)
            cancelPending(&effects)

        case .lockRemoved(let reason):
            interactionLocks.remove(reason)
            armExitIfEligible(now: now, &effects)

        case .displayChanged(let displayID):
            targetDisplayID = displayID
            cancelPending(&effects)
            if presentation == .preview && !isPinned && interactionLocks.isEmpty {
                changePresentation(.collapsed, &effects)
            }

        case .selectedSessionChanged(let sessionID):
            selectedSessionID = sessionID

        case .enlargedChanged(let enlarged):
            isEnlarged = enlarged

        case .notificationReceived:
            // Notifications may update app-owned chrome elsewhere. They never reveal
            // the panel, take focus, or start a terminal session.
            break
        }
        return effects
    }

    private mutating func armHover(now: Double, _ effects: inout [OverlayEffect]) {
        let timer = PendingTimer(token: freshToken(), deadline: now + max(0, hoverDwell))
        pendingHover = timer
        effects.append(.scheduleHover(token: timer.token, deadline: timer.deadline))
    }

    private mutating func armExitIfEligible(now: Double, _ effects: inout [OverlayEffect]) {
        guard presentation == .preview, !isPinned, interactionLocks.isEmpty,
              !pointerInTrigger, !pointerInPanel, pendingExit == nil else { return }
        let timer = PendingTimer(token: freshToken(), deadline: now + max(0, exitGrace))
        pendingExit = timer
        effects.append(.scheduleExit(token: timer.token, deadline: timer.deadline))
    }

    private mutating func cancelPending(_ effects: inout [OverlayEffect]) {
        guard pendingHover != nil || pendingExit != nil else { return }
        pendingHover = nil
        pendingExit = nil
        effects.append(.cancelTimers)
    }

    private mutating func freshToken() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }

    private mutating func changePresentation(_ next: OverlayPresentation, _ effects: inout [OverlayEffect]) {
        guard presentation != next else { return }
        presentation = next
        effects.append(.presentationChanged(next))
    }
}
