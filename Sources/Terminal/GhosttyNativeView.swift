// Adapted from Ghostty's macOS SurfaceView_AppKit.swift and NSEvent+Extension.swift
// at 982fe90d941e4b4aab4905ffcbcfdea60bd83343. Copyright Ghostty contributors.
// Ghostty is MIT licensed; see ThirdParty/Notices/Ghostty-LICENSE.

import AppKit
import CoreGraphics
import GhosttyKit

/// AppKit's input and render host for a surface owned by the session store.
/// The owner must clear `surface` before freeing the native surface. All access is on the main thread.
@MainActor
final class GhosttyNativeView: NSView, @preconcurrency NSTextInputClient {
    var surface: ghostty_surface_t? {
        didSet {
            guard surface != oldValue else { return }
            if let oldValue {
                ghostty_surface_set_focus(oldValue, false)
            }
            markedText = NSMutableAttributedString()
            selecting = false
            onInteractionLock?(false)
            if let surface {
                ghostty_surface_set_occlusion(surface, isPresented)
                syncGeometry()
                syncFocus()
            }
        }
    }

    var onActivate: (() -> Void)?
    /// The panel uses this to hold its presentation while selection or IME input is active.
    var onInteractionLock: ((Bool) -> Void)?

    private var isPresented = true
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var keyTextAccumulator: [String]?
    private var leadSurrogate: UInt16?
    private var lastKeyUp: (code: UInt16, time: TimeInterval)?
    private var selecting = false
    private var tracking: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var keyUpMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installInputObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installInputObservers()
    }

    isolated deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }

    private func installInputObservers() {
        // AppKit does not reliably deliver Command key-up through the responder chain.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            MainActor.assumeIsolated {
                if event.modifierFlags.contains(.command),
                   let self, self.window?.isKeyWindow == true,
                   self.window?.firstResponder === self {
                    self.keyUp(with: event)
                }
            }
            return event
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        syncFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeScreenNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.syncGeometry()
                        self?.syncFocus()
                    }
                })
            }
        }
        syncGeometry()
        syncFocus()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncGeometry()
    }

    /// The session remains alive when its panel is hidden. This only changes drawing visibility.
    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        if let surface { ghostty_surface_set_occlusion(surface, presented) }
        syncFocus()
    }

    func syncGeometry() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width.rounded()), UInt32(backing.height.rounded()))
        let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        ghostty_surface_set_display_id(surface, number?.uint32Value ?? 0)
    }

    /// Runs a Ghostty binding action, including `copy_to_clipboard` and `paste_from_clipboard`.
    @discardableResult
    func binding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
    }

    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let plainCommand = event.modifierFlags.intersection([.control, .option, .shift]).isEmpty
        switch character {
        case "c" where plainCommand: return binding("copy_to_clipboard")
        case "v" where plainCommand: return binding("paste_from_clipboard")
        default:
            // Let app-owned shortcuts (especially Command-W) reach the menu.
            if character == "w" || ("1"..."9").contains(character) {
                return super.performKeyEquivalent(with: event)
            }
            guard let surface else { return super.performKeyEquivalent(with: event) }
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.keycode = UInt32(event.keyCode)
            key.mods = Self.mods(event.modifierFlags)
            key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
            var bindingFlags = GHOSTTY_BINDING_FLAGS_CONSUMED
            let isBinding = (event.characters ?? "").withCString { pointer in
                key.text = pointer
                return ghostty_surface_key_is_binding(surface, key, &bindingFlags)
            }
            if isBinding && bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0 {
                keyDown(with: event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        let translation = translatedEvent(event, surface: surface)
        let hadMarkedText = hasMarkedText()
        keyTextAccumulator = []
        interpretKeyEvents([translation])
        let committed = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        syncPreedit(clearIfNeeded: hadMarkedText)
        if leadSurrogate != nil { return }

        let composing = hasMarkedText() || hadMarkedText
        if hadMarkedText, !committed.isEmpty {
            for text in committed where !Self.isComposingControl(text, composing: composing) {
                sendCommittedText(text, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            }
            // An IME may commit its preedit on an arrow key. Preserve navigation.
            if [0x7E, 0x7D, 0x7C].contains(event.keyCode) ||
                (event.keyCode == 0x7B && !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty) {
                sendKey(event, translation: translation, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            }
            return
        }
        if !committed.isEmpty {
            for text in committed where !Self.isComposingControl(text, composing: composing) {
                sendKey(event, translation: translation,
                        action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                        text: text)
            }
        } else if !Self.isComposingControl(event.characters, composing: composing) {
            sendKey(event, translation: translation,
                    action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                    text: Self.keyText(translation), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.timestamp != 0, let lastKeyUp,
           lastKeyUp.code == event.keyCode, lastKeyUp.time == event.timestamp { return }
        lastKeyUp = (event.keyCode, event.timestamp)
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText() else { return }
        let mask: UInt32
        switch event.keyCode {
        case 0x39: mask = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mask = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mask = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mask = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mask = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let isDown = Self.mods(event.modifierFlags).rawValue & mask != 0
        let rightSideBit: UInt
        switch event.keyCode {
        case 0x3C: rightSideBit = UInt(NX_DEVICERSHIFTKEYMASK)
        case 0x3E: rightSideBit = UInt(NX_DEVICERCTLKEYMASK)
        case 0x3D: rightSideBit = UInt(NX_DEVICERALTKEYMASK)
        case 0x36: rightSideBit = UInt(NX_DEVICERCMDKEYMASK)
        default: rightSideBit = 0
        }
        let action = isDown && (rightSideBit == 0 || event.modifierFlags.rawValue & rightSideBit != 0)
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKey(event, action: action)
    }

    private func sendKey(_ event: NSEvent, translation: NSEvent? = nil,
                         action: ghostty_input_action_e, text: String? = nil,
                         composing: Bool = false) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = Self.mods((translation?.modifierFlags ?? event.modifierFlags)
            .subtracting([.control, .command]))
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        key.composing = composing
        if let text, !text.isEmpty,
           let first = text.unicodeScalars.first,
           first.value >= 0x20 && first.value != 0x7F {
            text.withCString { pointer in
                key.text = pointer
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    private func sendCommittedText(_ text: String, action: ghostty_input_action_e) {
        guard let surface, !text.isEmpty else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { pointer in
            key.text = pointer
            _ = ghostty_surface_key(surface, key)
        }
    }

    private func translatedEvent(_ event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translated = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        var flags = event.modifierFlags
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT.rawValue),
                            (.control, GHOSTTY_MODS_CTRL.rawValue),
                            (.option, GHOSTTY_MODS_ALT.rawValue),
                            (.command, GHOSTTY_MODS_SUPER.rawValue)] {
            if translated.rawValue & bit != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        // Reuse the original event when modifiers match; some IMEs rely on its identity.
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                                modifierFlags: flags, timestamp: event.timestamp,
                                windowNumber: event.windowNumber, context: nil,
                                characters: event.characters(byApplyingModifiers: flags) ?? "",
                                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private static func keyText(_ event: NSEvent) -> String? {
        guard let text = event.characters, let scalar = text.unicodeScalars.first else { return nil }
        if text.unicodeScalars.count == 1 {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return text
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { bits |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { bits |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { bits |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { bits |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { bits |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { bits |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if flags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 { bits |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { bits |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 { bits |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(bits)
    }

    private func syncFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, isPresented && window?.isKeyWindow == true && window?.firstResponder === self)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if !markedText.string.isEmpty {
            markedText.string.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(markedText.string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
        onInteractionLock?(selecting || hasMarkedText())
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length)
                        : NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return markedSelection }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let string = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: string)
        } else if let string = string as? String {
            markedText = NSMutableAttributedString(string: string)
        } else { return }
        markedSelection = selectedRange
        if keyTextAccumulator == nil { syncPreedit() }
    }
    func unmarkText() {
        guard hasMarkedText() else { return }
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: NSNotFound, length: 0)
        if keyTextAccumulator == nil { syncPreedit() }
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return nil }
        actualRange?.pointee = NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
        return NSAttributedString(string: String(cString: bytes))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let committed: String
        if let attributed = string as? NSAttributedString {
            leadSurrogate = nil
            committed = attributed.string
        } else if let plain = string as? NSString {
            if plain.length == 1 {
                let code = plain.character(at: 0)
                if (0xD800...0xDBFF).contains(code) {
                    leadSurrogate = code
                    return
                }
                if (0xDC00...0xDFFF).contains(code) {
                    guard let lead = leadSurrogate,
                          let scalar = UnicodeScalar(0x10000 +
                              ((UInt32(lead) - 0xD800) << 10) + UInt32(code) - 0xDC00) else {
                        leadSurrogate = nil
                        return
                    }
                    leadSurrogate = nil
                    committed = String(scalar)
                } else {
                    leadSurrogate = nil
                    committed = plain as String
                }
            } else {
                leadSurrogate = nil
                committed = plain as String
            }
        } else { return }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(committed)
        } else {
            sendCommittedText(committed, action: GHOSTTY_ACTION_PRESS)
        }
    }
    override func doCommand(by selector: Selector) {
        // Key encoding runs after interpretKeyEvents; no AppKit text command is sent twice.
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    private func mousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, local.x, bounds.height - local.y,
                                 Self.mods(event.modifierFlags))
    }
    override func mouseEntered(with event: NSEvent) { mousePosition(event) }
    override func mouseMoved(with event: NSEvent) { mousePosition(event) }
    override func mouseDragged(with event: NSEvent) { mousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { mousePosition(event) }
    override func mouseExited(with event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        window?.makeFirstResponder(self)
        syncFocus()
        mousePosition(event)
        selecting = true
        onInteractionLock?(true)
        mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) {
        mousePosition(event)
        mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        selecting = false
        onInteractionLock?(hasMarkedText())
    }
    override func rightMouseDown(with event: NSEvent) {
        mousePosition(event)
        mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }
    override func rightMouseUp(with event: NSEvent) {
        mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }
    override func otherMouseDown(with event: NSEvent) {
        mousePosition(event)
        mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: Self.button(event.buttonNumber))
    }
    override func otherMouseUp(with event: NSEvent) {
        mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: Self.button(event.buttonNumber))
    }

    private func mouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e,
                             button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private static func button(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_EIGHT
        case 8: GHOSTTY_MOUSE_NINE
        case 9: GHOSTTY_MOUSE_TEN
        default: GHOSTTY_MOUSE_ELEVEN
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let phase: Int32
        switch event.momentumPhase {
        case .began: phase = 1
        case .stationary: phase = 2
        case .changed: phase = 3
        case .ended: phase = 4
        case .cancelled: phase = 5
        case .mayBegin: phase = 6
        default: phase = 0
        }
        let mods = (event.hasPreciseScrollingDeltas ? 1 : 0) | (phase << 1)
        let multiplier = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * multiplier,
                                    event.scrollingDeltaY * multiplier, mods)
    }
}
