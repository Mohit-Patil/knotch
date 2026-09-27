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
final class ShortcutController: NSObject {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: TerminalShortcut?
    var onToggle: (() -> Void)?
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
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

    func makeSettingsView(hoverEnabled: Bool, setHover: @escaping (Bool) -> Void,
                          onRecordingChange: @escaping (Bool) -> Void,
                          panelSize: CGSize, defaultPanelSize: CGSize, maximumPanelSize: CGSize,
                          panelSizeIsCustom: Bool,
                          setPanelSize: @escaping (CGSize?) -> Void,
                          notifications: AgentNotificationController,
                          clipboardPersists: Bool,
                          setClipboardPersists: @escaping (Bool) -> Void,
                          updates: UpdateController) -> NSView {
        NSHostingView(rootView: AccessSettings(controller: self, initialHover: hoverEnabled,
                                               setHover: setHover, onRecordingChange: onRecordingChange,
                                               panelSize: panelSize, defaultPanelSize: defaultPanelSize,
                                               maximumPanelSize: maximumPanelSize,
                                               panelSizeIsCustom: panelSizeIsCustom,
                                               setPanelSize: setPanelSize,
                                               notifications: notifications,
                                               clipboardPersists: clipboardPersists,
                                               setClipboardPersists: setClipboardPersists, updates: updates))
    }

    func shutdown() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
    }
}

private struct AccessSettings: View {
    @ObservedObject var updates: UpdateController
    let notifications: AgentNotificationController
    let controller: ShortcutController
    let setHover: (Bool) -> Void
    let onRecordingChange: (Bool) -> Void
    let defaultPanelSize: CGSize
    let maximumPanelSize: CGSize
    let setPanelSize: (CGSize?) -> Void
    let setClipboardPersists: (Bool) -> Void
    @State private var hover: Bool
    @State private var candidate: TerminalShortcut
    @State private var message = "Record a shortcut, then choose Enable."
    @State private var panelWidth: Double
    @State private var panelHeight: Double
    @State private var panelSizeIsCustom: Bool
    @State private var clipboardPersists: Bool

    init(controller: ShortcutController, initialHover: Bool, setHover: @escaping (Bool) -> Void,
         onRecordingChange: @escaping (Bool) -> Void,
         panelSize: CGSize, defaultPanelSize: CGSize, maximumPanelSize: CGSize,
         panelSizeIsCustom: Bool, setPanelSize: @escaping (CGSize?) -> Void,
         notifications: AgentNotificationController,
         clipboardPersists: Bool, setClipboardPersists: @escaping (Bool) -> Void,
         updates: UpdateController) {
        self.updates = updates
        self.notifications = notifications
        self.controller = controller
        self.setHover = setHover
        self.onRecordingChange = onRecordingChange
        self.defaultPanelSize = defaultPanelSize
        self.maximumPanelSize = maximumPanelSize
        self.setPanelSize = setPanelSize
        self.setClipboardPersists = setClipboardPersists
        _hover = State(initialValue: initialHover)
        _candidate = State(initialValue: controller.current ?? .suggested)
        _panelWidth = State(initialValue: Double(panelSize.width))
        _panelHeight = State(initialValue: Double(panelSize.height))
        _panelSizeIsCustom = State(initialValue: panelSizeIsCustom)
        _clipboardPersists = State(initialValue: clipboardPersists)
    }
    private var widthSelection: Binding<Double> {
        Binding(get: { panelWidth }, set: { value in
            panelWidth = value
            panelSizeIsCustom = true
            setPanelSize(CGSize(width: value, height: panelHeight))
        })
    }
    private var heightSelection: Binding<Double> {
        Binding(get: { panelHeight }, set: { value in
            panelHeight = value
            panelSizeIsCustom = true
            setPanelSize(CGSize(width: panelWidth, height: value))
        })
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "hand.point.up.left")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Toggle("Reveal on hover", isOn: $hover)
                    .onChange(of: hover) { _, value in setHover(value) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard shortcut").font(.headline)
                HStack(spacing: 12) {
                    ShortcutRecorder(shortcut: $candidate, onRecordingChange: onRecordingChange)
                        .frame(width: 170, height: 34)
                    Button("Enable") {
                        message = controller.register(candidate) ?? "Enabled \(candidate.display)."
                    }.buttonStyle(.borderedProminent)
                    Button("Disable") {
                        controller.disable()
                        message = "Shortcut disabled."
                    }
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Panel size").font(.headline)
                HStack {
                    Text("Width").frame(width: 48, alignment: .leading)
                    Slider(value: widthSelection,
                           in: min(520, Double(maximumPanelSize.width))...Double(maximumPanelSize.width))
                    Text("\(Int(panelWidth)) pt").monospacedDigit().frame(width: 68, alignment: .trailing)
                }
                HStack {
                    Text("Height").frame(width: 48, alignment: .leading)
                    Slider(value: heightSelection,
                           in: min(280, Double(maximumPanelSize.height))...Double(maximumPanelSize.height))
                    Text("\(Int(panelHeight)) pt").monospacedDigit().frame(width: 68, alignment: .trailing)
                }
                HStack {
                    Button("Reset to display default") {
                        panelWidth = Double(defaultPanelSize.width)
                        panelHeight = Double(defaultPanelSize.height)
                        panelSizeIsCustom = false
                        setPanelSize(nil)
                    }.disabled(!panelSizeIsCustom)
                    Spacer()
                    Text("Drag the bottom edge or lower corners")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Clipboard history").font(.headline)
                Toggle("Keep history after quitting Knotch", isOn: $clipboardPersists)
                    .onChange(of: clipboardPersists) { _, value in setClipboardPersists(value) }
                Text("Saved only on this Mac. Pause capture or clear items in the Clipboard tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates").font(.headline)
                HStack {
                    Button("Check for updates") { updates.checkForUpdates(nil) }
                        .disabled(!updates.canCheck || updates.canRestart)
                    Button("Restart to update") { updates.restartToUpdate(nil) }
                        .disabled(!updates.canRestart)
                }
                Text(updates.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            AgentNotificationSettings(controller: notifications)
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .preferredColorScheme(.dark)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: TerminalShortcut
    let onRecordingChange: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { shortcut = $0 }
        view.onRecordingChange = onRecordingChange
        view.text = shortcut.display
        return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.text = shortcut.display }
}

@MainActor
private final class RecorderView: NSView {
    var onRecord: ((TerminalShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
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
    private func beginRecording() {
        recording = true
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    private func endRecording() {
        recording = false
        onRecordingChange?(false)
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool {
        if recording { endRecording() }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { endRecording(); return }
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
        endRecording()
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
