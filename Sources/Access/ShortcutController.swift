import AppKit
import Carbon
import SwiftUI

struct TerminalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
    static let suggested = TerminalShortcut(keyCode: 50, modifiers: UInt32(cmdKey | optionKey), display: "⌘⌥`")
}

/// Public registered-hot-key API; no global keyboard monitor or permission prompt.
@MainActor
final class ShortcutController {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: TerminalShortcut?
    var onToggle: (() -> Void)?
    var settingsWindow: NSWindow?
    private let defaults = UserDefaults.standard

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            MainActor.assumeIsolated {
                guard let data else { return OSStatus(eventNotHandledErr) }
                Unmanaged<ShortcutController>.fromOpaque(data).takeUnretainedValue().onToggle?()
                return noErr
            }
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func restoreConfirmedShortcut() -> String? {
        guard let data = defaults.data(forKey: "access.shortcut.v1") else { return nil }
        guard let saved = try? JSONDecoder().decode(TerminalShortcut.self, from: data) else {
            return "The saved shortcut could not be read. Choose a new shortcut; the menu remains available."
        }
        return register(saved, persist: false)
    }

    @discardableResult
    func register(_ shortcut: TerminalShortcut, persist: Bool = true) -> String? {
        if shortcut == current { return nil }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4B4E5443, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &next)
        guard status == noErr else {
            return "macOS could not register \(shortcut.display) (error \(status)). It may already be in use. Record another shortcut or use the menu."
        }
        if let registration { UnregisterEventHotKey(registration) }
        registration = next
        current = shortcut
        if persist, let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "access.shortcut.v1") }
        return nil
    }

    func disable() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        current = nil
        defaults.removeObject(forKey: "access.shortcut.v1")
    }

    func showSettings(hoverEnabled: Bool, setHover: @escaping (Bool) -> Void) {
        if let settingsWindow { NSApp.activate(); settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Knotch Access"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AccessSettings(controller: self, initialHover: hoverEnabled, setHover: setHover))
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func shutdown() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
    }
}

private struct AccessSettings: View {
    let controller: ShortcutController
    let setHover: (Bool) -> Void
    @State private var hover: Bool
    @State private var candidate: TerminalShortcut
    @State private var message = "Record a shortcut, then choose Enable. Menu access is always available."

    init(controller: ShortcutController, initialHover: Bool, setHover: @escaping (Bool) -> Void) {
        self.controller = controller
        self.setHover = setHover
        _hover = State(initialValue: initialHover)
        _candidate = State(initialValue: controller.current ?? .suggested)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your terminal, at the notch").font(.title2.weight(.semibold))
            Text("Hover to inspect. Click or use your shortcut to type. Hiding keeps your tools running; quitting ends the session.")
                .foregroundStyle(.secondary)
            Toggle("Reveal on hover", isOn: $hover).onChange(of: hover) { _, value in setHover(value) }
            HStack {
                ShortcutRecorder(shortcut: $candidate).frame(width: 160, height: 32)
                Button("Enable Shortcut") {
                    message = controller.register(candidate) ?? "Enabled \(candidate.display). Press it to open or hide the terminal."
                }.buttonStyle(.borderedProminent)
                Button("Disable") { controller.disable(); message = "Shortcut disabled. Use the menu or hover." }
            }
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(24).frame(width: 470, height: 320)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: TerminalShortcut
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { shortcut = $0 }
        view.text = shortcut.display
        return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.text = shortcut.display }
}

@MainActor
private final class RecorderView: NSView {
    var onRecord: ((TerminalShortcut) -> Void)?
    var text = "" { didSet { needsDisplay = true } }
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record terminal shortcut")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    private func beginRecording() { recording = true; window?.makeFirstResponder(self); needsDisplay = true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { recording = false; needsDisplay = true; return }
        if !recording { beginRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return }
        var modifiers: UInt32 = 0
        var display = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); display += "⌘" }
        display += event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        onRecord?(TerminalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: display))
        recording = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.2) : NSColor.controlBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let title = recording ? "Press shortcut…" : text
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let size = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
