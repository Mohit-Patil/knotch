import Foundation
import Observation
import SwiftUI

enum FocusTool: String, CaseIterable, Identifiable {
    case notes, todos, timer, teleprompter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Quick Notes"
        case .todos: "To-dos"
        case .timer: "Timer"
        case .teleprompter: "Teleprompter"
        }
    }

    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .todos: "checklist"
        case .timer: "timer"
        case .teleprompter: "text.alignleft"
        }
    }
}

struct FocusNote: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String = ""
    var modifiedAt: Date = .now

    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled note"
    }
}

struct FocusTodo: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var isDone: Bool = false
    var createdAt: Date = .now
}

enum FocusTimerMode: String, Codable, CaseIterable {
    case focus, shortBreak, longBreak, custom

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        case .custom: "Custom"
        }
    }

    var minutes: Int {
        switch self {
        case .focus: 25
        case .shortBreak: 5
        case .longBreak: 15
        case .custom: 10
        }
    }
}

@MainActor @Observable
final class FocusToolsStore {
    private struct Snapshot: Codable {
        var notes: [FocusNote] = []
        var todos: [FocusTodo] = []
        var timerMode: FocusTimerMode = .focus
        var customMinutes = 10
        var timerRemaining: TimeInterval = 25 * 60
        var timerDeadline: Date?
        var completedFocusSessions = 0
        var teleprompterText = ""
        var teleprompterFontSize = 32.0
        var teleprompterSpeed = 32.0
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    private var snapshot: Snapshot {
        didSet { save() }
    }

    @ObservationIgnored private var teleprompterStartedAt: Date?
    @ObservationIgnored private var teleprompterAccumulatedOffset = 0.0
    @ObservationIgnored private var timerHeartbeat: Timer?
    private(set) var teleprompterPlaying = false

    /// Pass a separate UserDefaults suite and key for fixtures; production uses only this app's defaults.
    init(defaults: UserDefaults = .standard, storageKey: String = "focus.tools.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
        reconcileTimer()
        updateTimerHeartbeat()
    }

    var notes: [FocusNote] { snapshot.notes }
    var todos: [FocusTodo] { snapshot.todos }
    var timerMode: FocusTimerMode { snapshot.timerMode }
    var completedFocusSessions: Int { snapshot.completedFocusSessions }
    var customMinutes: Int { snapshot.customMinutes }
    var teleprompterText: String {
        get { snapshot.teleprompterText }
        set { snapshot.teleprompterText = newValue }
    }
    var teleprompterFontSize: Double {
        get { snapshot.teleprompterFontSize }
        set { snapshot.teleprompterFontSize = min(60, max(20, newValue)) }
    }
    var teleprompterSpeed: Double {
        get { snapshot.teleprompterSpeed }
        set {
            if teleprompterPlaying {
                teleprompterAccumulatedOffset = teleprompterOffset()
                teleprompterStartedAt = .now
            }
            snapshot.teleprompterSpeed = min(100, max(10, newValue))
        }
    }

    @discardableResult
    func addNote() -> UUID {
        let note = FocusNote()
        snapshot.notes.insert(note, at: 0)
        return note.id
    }

    func updateNote(_ id: UUID, text: String) {
        guard let index = snapshot.notes.firstIndex(where: { $0.id == id }) else { return }
        snapshot.notes[index].text = text
        snapshot.notes[index].modifiedAt = .now
    }

    func deleteNote(_ id: UUID) {
        snapshot.notes.removeAll { $0.id == id }
    }

    func addTodo(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        snapshot.todos.insert(FocusTodo(title: trimmed), at: 0)
    }

    func toggleTodo(_ id: UUID) {
        guard let index = snapshot.todos.firstIndex(where: { $0.id == id }) else { return }
        snapshot.todos[index].isDone.toggle()
    }

    func deleteTodo(_ id: UUID) {
        snapshot.todos.removeAll { $0.id == id }
    }

    func setTimerMode(_ mode: FocusTimerMode) {
        snapshot.timerMode = mode
        snapshot.timerDeadline = nil
        snapshot.timerRemaining = TimeInterval((mode == .custom ? snapshot.customMinutes : mode.minutes) * 60)
        updateTimerHeartbeat()
    }

    func setCustomMinutes(_ minutes: Int) {
        snapshot.customMinutes = min(180, max(1, minutes))
        if snapshot.timerMode == .custom { resetTimer() }
    }

    var timerIsRunning: Bool { snapshot.timerDeadline != nil && timerRemaining() > 0 }
    var timerIsFinished: Bool { snapshot.timerDeadline != nil && timerRemaining() == 0 }

    func timerRemaining(at date: Date = .now) -> TimeInterval {
        if let deadline = snapshot.timerDeadline {
            return max(0, deadline.timeIntervalSince(date))
        }
        return max(0, snapshot.timerRemaining)
    }

    func startPauseTimer() {
        reconcileTimer()
        if snapshot.timerDeadline != nil {
            snapshot.timerRemaining = timerRemaining()
            snapshot.timerDeadline = nil
        } else {
            if snapshot.timerRemaining <= 0 { resetTimer() }
            snapshot.timerDeadline = Date().addingTimeInterval(snapshot.timerRemaining)
        }
        updateTimerHeartbeat()
    }

    func resetTimer() {
        snapshot.timerDeadline = nil
        snapshot.timerRemaining = TimeInterval((snapshot.timerMode == .custom
            ? snapshot.customMinutes : snapshot.timerMode.minutes) * 60)
        updateTimerHeartbeat()
    }

    /// A saved deadline keeps time correct through panel changes, sleep, and app relaunch.
    func reconcileTimer(at date: Date = .now) {
        guard let deadline = snapshot.timerDeadline, deadline <= date else { return }
        if snapshot.timerMode == .focus { snapshot.completedFocusSessions += 1 }
        snapshot.timerDeadline = nil
        snapshot.timerRemaining = 0
        updateTimerHeartbeat()
    }

    func teleprompterOffset(at date: Date = .now) -> Double {
        let elapsed = teleprompterStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return teleprompterAccumulatedOffset + elapsed * snapshot.teleprompterSpeed
    }

    func playTeleprompter() {
        guard !snapshot.teleprompterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !teleprompterPlaying else { return }
        teleprompterStartedAt = .now
        teleprompterPlaying = true
    }

    func pauseTeleprompter() {
        guard teleprompterPlaying else { return }
        teleprompterAccumulatedOffset = teleprompterOffset()
        teleprompterStartedAt = nil
        teleprompterPlaying = false
    }

    func resetTeleprompter() {
        teleprompterStartedAt = nil
        teleprompterAccumulatedOffset = 0
        teleprompterPlaying = false
    }

    func stop() {
        pauseTeleprompter()
        timerHeartbeat?.invalidate()
        timerHeartbeat = nil
        save()
    }

    private func updateTimerHeartbeat() {
        timerHeartbeat?.invalidate()
        timerHeartbeat = nil
        guard snapshot.timerDeadline != nil else { return }
        timerHeartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileTimer() }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct FocusToolsView: View {
    let tool: FocusTool
    @Bindable var store: FocusToolsStore
    @State private var selectedNoteID: UUID?
    @State private var newTodo = ""
    @State private var editingScript = true
    @State private var scrollPosition = ScrollPosition()

    private let accent = Color(red: 0.54, green: 0.72, blue: 0.98)
    private let surface = Color(red: 0.105, green: 0.111, blue: 0.124)

    init(tool: FocusTool, store: FocusToolsStore) {
        self.tool = tool
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                Text(tool.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                headerAccessory
            }

            Group {
                switch tool {
                case .notes: notesView
                case .todos: todosView
                case .timer: timerView
                case .teleprompter: teleprompterView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch tool {
        case .notes:
            Button {
                selectedNoteID = store.addNote()
            } label: {
                Label("New note", systemImage: "plus")
            }
            .buttonStyle(FocusSmallButtonStyle())
        case .todos:
            Text("\(store.todos.filter { !$0.isDone }.count) remaining")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        case .timer:
            Text("\(store.completedFocusSessions) focus sessions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        case .teleprompter:
            Button(editingScript ? "Read" : "Edit") {
                if !editingScript { store.pauseTeleprompter() }
                editingScript.toggle()
            }
            .buttonStyle(FocusSmallButtonStyle())
        }
    }

    private var notesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.notes.isEmpty {
                ContentUnavailableView("No notes yet", systemImage: "note.text",
                                       description: Text("Capture a thought without leaving the notch."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.notes) { note in
                            Button {
                                selectedNoteID = note.id
                            } label: {
                                Text(note.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 150)
                            }
                            .buttonStyle(FocusChipStyle(selected: selectedNoteID == note.id, accent: accent))
                            .accessibilityLabel("Open note: \(note.title)")
                        }
                    }
                }
                if let note = selectedNote {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(
                            get: { store.notes.first(where: { $0.id == note.id })?.text ?? "" },
                            set: { store.updateNote(note.id, text: $0) }
                        ))
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Note text")
                        if note.text.isEmpty {
                            Text("Start typing…")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.3))
                                .padding(.leading, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(10)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                    HStack {
                        Text("Saved automatically")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Button(role: .destructive) {
                            store.deleteNote(note.id)
                            selectedNoteID = store.notes.first?.id
                        } label: {
                            Label("Delete note", systemImage: "trash")
                        }
                        .buttonStyle(FocusSmallButtonStyle())
                    }
                }
            }
        }
        .onAppear {
            if !store.notes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = store.notes.first?.id
            }
        }
    }

    private var selectedNote: FocusNote? {
        store.notes.first(where: { $0.id == selectedNoteID })
    }

    private var todosView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                TextField("Add a task", text: $newTodo)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addTodo)
                    .accessibilityLabel("New task")
                Button(action: addTodo) {
                    Image(systemName: "plus")
                }
                .buttonStyle(FocusSmallButtonStyle())
                .disabled(newTodo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add task")
            }
            .padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            if store.todos.isEmpty {
                ContentUnavailableView("Nothing to do", systemImage: "checkmark.circle",
                                       description: Text("Add a task to keep it close at hand."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.todos.sorted {
                            if $0.isDone != $1.isDone { return !$0.isDone }
                            return $0.createdAt > $1.createdAt
                        }) { todo in
                            HStack(spacing: 10) {
                                Button { store.toggleTodo(todo.id) } label: {
                                    Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(todo.isDone ? accent : .white.opacity(0.48))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(todo.isDone ? "Mark \(todo.title) incomplete" : "Complete \(todo.title)")
                                Text(todo.title)
                                    .font(.system(size: 13))
                                    .strikethrough(todo.isDone)
                                    .foregroundStyle(.white.opacity(todo.isDone ? 0.42 : 0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { store.deleteTodo(todo.id) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(todo.title)")
                            }
                            .padding(12)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
        }
    }

    private func addTodo() {
        store.addTodo(newTodo)
        newTodo = ""
    }

    private var timerView: some View {
        VStack(spacing: 19) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(FocusTimerMode.allCases, id: \.self) { mode in
                        Button(mode.title) { store.setTimerMode(mode) }
                            .buttonStyle(FocusChipStyle(selected: store.timerMode == mode, accent: accent))
                    }
                }
            }
            if store.timerMode == .custom {
                Stepper("\(store.customMinutes) minutes", value: Binding(
                    get: { store.customMinutes },
                    set: { store.setCustomMinutes($0) }
                ), in: 1...180)
                .font(.system(size: 12))
                .frame(maxWidth: 200)
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                let remaining = store.timerRemaining(at: timeline.date)
                VStack(spacing: 6) {
                    Text(timerClock(remaining))
                        .font(.system(size: 58, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Time remaining \(timerClock(remaining))")
                    Text(remaining == 0 ? "Session complete" : store.timerIsRunning ? "In progress" : "Ready when you are")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(remaining == 0 ? accent : .white.opacity(0.46))
                }
            }
            HStack(spacing: 10) {
                Button {
                    store.startPauseTimer()
                } label: {
                    Label(store.timerIsRunning ? "Pause" : "Start", systemImage: store.timerIsRunning ? "pause.fill" : "play.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(FocusPrimaryButtonStyle(accent: accent))
                Button { store.resetTimer() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(FocusSmallButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .onAppear { store.reconcileTimer() }
    }

    private func timerClock(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, interval)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var teleprompterView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "textformat.size")
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $store.teleprompterFontSize, in: 20...60)
                    .accessibilityLabel("Text size")
                Text("\(Int(store.teleprompterFontSize)) pt")
                    .frame(width: 38, alignment: .trailing)
                Image(systemName: "speedometer")
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $store.teleprompterSpeed, in: 10...100)
                    .accessibilityLabel("Scroll speed")
                Text("\(Int(store.teleprompterSpeed))")
                    .frame(width: 24, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.64))

            if editingScript {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.teleprompterText)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Teleprompter script")
                    if store.teleprompterText.isEmpty {
                        Text("Paste or write your script here…")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            } else {
                ScrollView {
                    Text(store.teleprompterText.isEmpty ? "Add a script in Edit mode." : store.teleprompterText)
                        .font(.system(size: store.teleprompterFontSize, weight: .medium))
                        .lineSpacing(10)
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 90)
                }
                .scrollIndicators(.hidden)
                .scrollPosition($scrollPosition)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 11))
                .onAppear { scrollPosition.scrollTo(y: store.teleprompterOffset()) }
                .task(id: store.teleprompterPlaying) {
                    while store.teleprompterPlaying && !Task.isCancelled {
                        scrollPosition.scrollTo(y: store.teleprompterOffset())
                        try? await Task.sleep(for: .milliseconds(33))
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    if editingScript { editingScript = false }
                    if store.teleprompterPlaying { store.pauseTeleprompter() }
                    else { store.playTeleprompter() }
                } label: {
                    Label(store.teleprompterPlaying ? "Pause" : "Play",
                          systemImage: store.teleprompterPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(FocusPrimaryButtonStyle(accent: accent))
                .disabled(store.teleprompterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    store.resetTeleprompter()
                    scrollPosition.scrollTo(edge: .top)
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(FocusSmallButtonStyle())
                Spacer()
                Text("Saved automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
    }
}

private struct FocusSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.56 : 0.8))
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(.white.opacity(configuration.isPressed ? 0.11 : 0.065),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct FocusPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 13)
            .frame(height: 31)
            .background(accent.opacity(configuration.isPressed ? 0.72 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FocusChipStyle: ButtonStyle {
    let selected: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? .white : .white.opacity(0.65))
            .padding(.horizontal, 11)
            .frame(height: 27)
            .background(selected ? accent.opacity(0.18) : .white.opacity(0.05), in: Capsule())
            .overlay {
                Capsule().strokeBorder(selected ? accent.opacity(0.4) : .white.opacity(0.07), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}
