import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AgentNotificationController {
    struct Notice: Identifiable {
        let id = UUID()
        let sessionID: UUID?
        let title: String
        let message: String
    }
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "notifications.enabled.v1"); if !enabled { clear() } } }
    var onLeft: Bool { didSet { defaults.set(onLeft, forKey: "notifications.left.v1"); refresh() } }
    private(set) var notices: [Notice] = []
    var onOpen: ((UUID) -> Void)?
    var screenProvider: (() -> NSScreen?)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var window: NSPanel?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suspensions: Set<String> = []
    @ObservationIgnored private var lastNotice: (UUID?, String, Date)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "notifications.enabled.v1") as? Bool ?? true
        onLeft = defaults.bool(forKey: "notifications.left.v1")
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func setSuspended(_ reason: String, _ suspended: Bool) {
        let changed = suspended ? suspensions.insert(reason).inserted : suspensions.remove(reason) != nil
        if changed { refresh() }
    }
    func receive(sessionID: UUID?, title: String, message: String) {
        guard enabled else { return }
        let cleanTitle = Self.clean(title, limit: 60)
        let cleanMessage = Self.clean(message, limit: 140)
        let fingerprint = cleanTitle + cleanMessage
        if let lastNotice, lastNotice.0 == sessionID, lastNotice.1 == fingerprint,
           Date().timeIntervalSince(lastNotice.2) < 2 { return }
        lastNotice = (sessionID, fingerprint, Date())
        // One pending indicator per terminal. New updates do not make a stack of windows.
        notices.removeAll { $0.sessionID == sessionID }
        notices.append(Notice(sessionID: sessionID, title: cleanTitle.isEmpty ? "Terminal update" : cleanTitle,
                              message: cleanMessage.isEmpty ? "Ready for your attention" : cleanMessage))
        if notices.count > 20 { notices.removeFirst(notices.count - 20) }
        refresh()
    }
    func acknowledge(_ id: UUID) {
        notices.removeAll { $0.sessionID == id }
        refresh()
    }
    func retainSessions(_ ids: Set<UUID>) {
        let count = notices.count
        notices.removeAll { $0.sessionID.map { !ids.contains($0) } ?? false }
        if count != notices.count { refresh() }
    }
    func openFirst() {
        guard let notice = notices.first else { return }
        notices.removeFirst()
        refresh()
        if let id = notice.sessionID { onOpen?(id) }
    }
    func dismissFirst() {
        guard !notices.isEmpty else { return }
        notices.removeFirst()
        refresh()
    }
    func preview() { receive(sessionID: nil, title: "Preview", message: "Your agent's response is ready") }
    func clear() { notices.removeAll(); refresh() }
    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        clear()
        window?.close()
        window = nil
    }
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.prefix(4096).filter {
            !CharacterSet.controlCharacters.contains($0) && !$0.properties.isBidiControl && $0.properties.generalCategory != .format
        }
        return String(String(String.UnicodeScalarView(scalars)).prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func frame(screen: NSRect, notch: NSRect?, menuHeight: CGFloat, left: Bool) -> NSRect {
        let width = min(250, max(100, screen.width / 2 - 100))
        let anchor = notch ?? NSRect(x: screen.midX - 80, y: screen.maxY - menuHeight, width: 160, height: menuHeight)
        let desiredX = left ? anchor.minX - width - 6 : anchor.maxX + 6
        return NSRect(x: min(max(screen.minX + 8, desiredX), screen.maxX - width - 8),
                      y: screen.maxY - max(40, menuHeight), width: width, height: 40)
    }
    private func refresh() {
        generation += 1
        guard enabled, suspensions.isEmpty, let notice = notices.first, let screen = screenProvider?() ?? NSScreen.main else {
            window?.orderOut(nil)
            return
        }
        if window == nil {
            let panel = NoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window = panel
        }
        let notch: NSRect?
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = NSRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else { notch = nil }
        let frame = Self.frame(screen: screen.frame, notch: notch,
                               menuHeight: max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY), left: onLeft)
        window?.setFrame(frame, display: true)
        window?.contentView = NSHostingView(rootView: NoticeDroplet(notice: notice, count: notices.count, onLeft: onLeft,
                                                                    open: { [weak self] in self?.openFirst() },
                                                                    dismiss: { [weak self] in self?.dismissFirst() }).id(generation))
        // Presentation itself must not activate the app or change the user's first responder.
        window?.orderFrontRegardless()
    }
    #if HARNESS_TESTS
    var panelForFixture: NSPanel? { window }
    #endif
}

private final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NoticeDroplet: View {
    let notice: AgentNotificationController.Notice
    let count: Int
    let onLeft: Bool
    let open: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var emerged = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(notice.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if count > 1 { Text("+\(count - 1)").font(.caption2.monospacedDigit()).foregroundStyle(.mint) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notice.title). \(notice.message). Open terminal")
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).padding(6) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss agent notification")
        }
        .padding(.leading, 12).padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .padding(2)
        .scaleEffect(x: emerged || reduceMotion ? 1 : 0.08, y: emerged || reduceMotion ? 1 : 0.5,
                     anchor: onLeft ? .trailing : .leading)
        .opacity(emerged ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.55, dampingFraction: 0.68)) { emerged = true }
        }
        .preferredColorScheme(.dark)
    }
}

struct AgentNotificationSettings: View {
    @Bindable var controller: AgentNotificationController
    @State private var copied = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent notifications").font(.headline)
            Toggle("Show updates beside the notch", isOn: $controller.enabled)
            HStack {
                Picker("Side", selection: $controller.onLeft) {
                    Text("Right").tag(false)
                    Text("Left").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 230)
                Button("Preview motion") { controller.preview() }.disabled(!controller.enabled)
            }
            HStack {
                Button("Copy Claude launch command") { copy(Self.claudeCommand, name: "Claude") }
                Button("Copy Codex launch command") { copy(Self.codexCommand, name: "Codex") }
            }
            Text(copied.isEmpty ? "Launch an agent with notifications enabled. Updates stay until opened or dismissed." : copied)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func copy(_ command: String, name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = "\(name) command copied. Paste it into a terminal to start; your global configuration is unchanged."
    }
    static let codexCommand = "codex -c 'tui.notifications=[\"agent-turn-complete\"]' -c 'tui.notification_method=\"osc9\"'"
    static var claudeCommand: String {
        let output = #"{"terminalSequence":"\u001b]777;notify;Claude Code;Response complete\u0007"}"#
        let command = "printf '%s\\n' " + quote(output)
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
        return "claude --settings " + quote(json)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
