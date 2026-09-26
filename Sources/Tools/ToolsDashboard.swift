import SwiftUI
import Observation

enum KnotchTool: String, CaseIterable, Identifiable {
    case notes, todos, timer, calendar, reminders, teleprompter
    case files, nowPlaying, mirror, chat, aiUsage
    case weather, stocks, converter, emoji, shortcuts, stats, keepAwake, volume

    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: "Quick Notes"
        case .todos: "To-dos"
        case .timer: "Focus & Timers"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .teleprompter: "Teleprompter"
        case .files: "File Shelf"
        case .nowPlaying: "Now Playing"
        case .mirror: "Mirror"
        case .chat: "Ask Knotch"
        case .aiUsage: "AI Usage"
        case .weather: "Weather"
        case .stocks: "Stocks"
        case .converter: "Convert"
        case .emoji: "Emoji"
        case .shortcuts: "Shortcuts"
        case .stats: "System Stats"
        case .keepAwake: "Keep Awake"
        case .volume: "Sound"
        }
    }
    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .todos: "checklist"
        case .timer: "timer"
        case .calendar: "calendar"
        case .reminders: "list.bullet.circle"
        case .teleprompter: "text.alignleft"
        case .files: "tray.full"
        case .nowPlaying: "music.note"
        case .mirror: "camera"
        case .chat: "sparkles"
        case .aiUsage: "gauge.with.dots.needle.33percent"
        case .weather: "cloud.sun"
        case .stocks: "chart.xyaxis.line"
        case .converter: "arrow.left.arrow.right"
        case .emoji: "face.smiling"
        case .shortcuts: "square.stack.3d.up"
        case .stats: "waveform.path.ecg"
        case .keepAwake: "cup.and.saucer"
        case .volume: "speaker.wave.2"
        }
    }
    var detail: String {
        switch self {
        case .notes: "A thought, kept for later"
        case .todos: "A little less to remember"
        case .timer: "Countdowns and Pomodoro"
        case .calendar: "Your day at a glance"
        case .reminders: "Your Apple Reminders"
        case .teleprompter: "Keep your words in view"
        case .files: "Drop, keep, share, AirDrop"
        case .nowPlaying: "Music and Spotify controls"
        case .mirror: "A quick camera check"
        case .chat: "Private, on-device AI"
        case .aiUsage: "Keep an eye on your limits"
        case .weather: "Today and the week ahead"
        case .stocks: "Your market watchlist"
        case .converter: "Units and currencies"
        case .emoji: "Find and copy an emoji"
        case .shortcuts: "Your automations, one tap"
        case .stats: "CPU, memory and network"
        case .keepAwake: "Keep your Mac ready"
        case .volume: "Output volume and mute"
        }
    }
    var category: String {
        switch self {
        case .notes, .todos, .timer, .calendar, .reminders, .teleprompter: "Focus"
        case .files, .nowPlaying, .mirror, .chat, .aiUsage: "Everyday"
        default: "Utilities"
        }
    }
    var tint: Color {
        switch category {
        case "Focus": .orange
        case "Everyday": .mint
        default: .blue
        }
    }
}

@MainActor @Observable
final class ToolsStore {
    var selected: KnotchTool? {
        didSet {
            if oldValue != selected { mirror.stop(); focus.pauseTeleprompter() }
            updateVisibility()
        }
    }
    var query = ""
    private(set) var favorites: Set<KnotchTool>
    private(set) var isVisible = false
    @ObservationIgnored private let defaults: UserDefaults
    let context = ToolsContext()
    let focus: FocusToolsStore
    let system = SystemToolsStore()
    let quick = QuickToolsStore()
    let agenda = AgendaToolsStore()
    let files = FileShelfStore()
    let mirror = MirrorToolsStore()
    let media = MediaToolsStore()
    let liveData: LiveDataToolsStore
    let chat = LocalAIToolsStore()
    let usage = AIUsageToolsStore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focus = FocusToolsStore(defaults: defaults)
        liveData = LiveDataToolsStore(defaults: defaults)
        favorites = Set((defaults.stringArray(forKey: "tools.favorites.v1") ?? ["notes", "timer", "files", "nowPlaying"])
            .compactMap(KnotchTool.init(rawValue:)))
    }
    func toggleFavorite(_ tool: KnotchTool) {
        if favorites.contains(tool) { favorites.remove(tool) } else { favorites.insert(tool) }
        defaults.set(favorites.map(\.rawValue).sorted(), forKey: "tools.favorites.v1")
    }
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible { mirror.stop(); focus.pauseTeleprompter() }
        updateVisibility()
    }
    private func updateVisibility() {
        system.setVisible(isVisible && (selected == .stats || selected == .volume),
                          tool: selected == .stats ? .stats : (selected == .volume ? .volume : nil))
        media.setVisible(isVisible && selected == .nowPlaying)
        agenda.setVisible(isVisible && (selected == .calendar || selected == .reminders),
                          tool: selected == .calendar ? .calendar : (selected == .reminders ? .reminders : nil))
    }
    func shutdown() {
        setVisible(false)
        focus.stop()
        quick.shutdown()
        mirror.shutdown()
        media.shutdown()
        system.shutdown()
        agenda.shutdown()
        files.shutdown()
        liveData.shutdown()
        chat.shutdown()
        usage.shutdown()
    }
}

struct ToolsDashboard: View {
    @Bindable var store: ToolsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let tool = store.selected {
                    Button { store.selected = nil } label: {
                        Label("All Tools", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Text(tool.title).font(.headline)
                    Spacer()
                    favoriteButton(tool)
                } else {
                    Text("Your tools").font(.title2.weight(.semibold))
                    Spacer()
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a tool", text: $store.query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Find a tool")
                        if !store.query.isEmpty {
                            Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear tool search")
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: 240)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Divider().overlay(.white.opacity(0.04))
            if let selected = store.selected {
                detail(selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(selected)
            } else {
                catalog
            }
        }
        .background(Color(white: 0.065))
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: store.selected)
    }

    private var catalog: some View {
        ScrollView {
            let filtered = KnotchTool.allCases.filter {
                store.query.isEmpty || "\($0.title) \($0.detail) \($0.category)".localizedCaseInsensitiveContains(store.query)
            }
            LazyVStack(alignment: .leading, spacing: 20) {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: store.query)
                } else {
                    if store.query.isEmpty && !store.favorites.isEmpty {
                        favorites(filtered.filter { store.favorites.contains($0) })
                    }
                    ForEach(["Focus", "Everyday", "Utilities"], id: \.self) { category in
                        let members = filtered.filter { $0.category == category }
                        if !members.isEmpty { section(category, tools: members) }
                    }
                }
            }
            .padding(20)
        }
    }

    private func favorites(_ tools: [KnotchTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Favourites").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(tools) { tool in
                        Button { store.selected = tool } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(tool.tint)
                                Text(tool.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 124, height: 54, alignment: .leading)
                            .padding(12)
                            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(tool.title)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func section(_ title: String, tools: [KnotchTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 10)], spacing: 10) {
                ForEach(tools) { tool in
                    HStack(alignment: .top, spacing: 0) {
                        Button { store.selected = tool } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(tool.tint)
                                    .frame(height: 25)
                                Text(tool.title).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        favoriteButton(tool).padding(.top, 12).padding(.trailing, 10)
                    }
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.06)))
                }
            }
        }
    }
    private func favoriteButton(_ tool: KnotchTool) -> some View {
        Button { store.toggleFavorite(tool) } label: {
            Image(systemName: store.favorites.contains(tool) ? "star.fill" : "star")
                .foregroundStyle(store.favorites.contains(tool) ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(store.favorites.contains(tool) ? "Remove from favourites" : "Add to favourites")
        .accessibilityLabel("\(store.favorites.contains(tool) ? "Unfavourite" : "Favourite") \(tool.title)")
    }
    @ViewBuilder private func detail(_ tool: KnotchTool) -> some View {
        switch tool {
        case .notes: FocusToolsView(tool: .notes, store: store.focus)
        case .todos: FocusToolsView(tool: .todos, store: store.focus)
        case .timer: FocusToolsView(tool: .timer, store: store.focus)
        case .teleprompter: FocusToolsView(tool: .teleprompter, store: store.focus)
        case .files: FileShelfToolsView(store: store.files, context: store.context)
        case .mirror: MirrorToolsView(store: store.mirror, context: store.context)
        case .nowPlaying: MediaToolsView(store: store.media, context: store.context)
        case .calendar: AgendaToolsView(tool: .calendar, store: store.agenda, context: store.context)
        case .reminders: AgendaToolsView(tool: .reminders, store: store.agenda, context: store.context)
        case .stats: SystemToolsView(tool: .stats, store: store.system)
        case .keepAwake: SystemToolsView(tool: .keepAwake, store: store.system)
        case .volume: SystemToolsView(tool: .volume, store: store.system)
        case .shortcuts: QuickToolsView(tool: .shortcuts, store: store.quick)
        case .emoji: QuickToolsView(tool: .emoji, store: store.quick)
        case .converter: QuickToolsView(tool: .converter, store: store.quick)
        case .weather: LiveDataToolsView(tool: .weather, store: store.liveData)
        case .stocks: LiveDataToolsView(tool: .stocks, store: store.liveData)
        case .chat: LocalAIToolsView(store: store.chat)
        case .aiUsage: AIUsageToolsView(store: store.usage)
        }
    }
}
