import AppKit
import EventKit
import Observation
import SwiftUI

enum AgendaTool: String {
    case calendar
    case reminders

    var title: String { self == .calendar ? "Calendar" : "Reminders" }
    var symbol: String { self == .calendar ? "calendar" : "checklist" }
    var entityType: EKEntityType { self == .calendar ? .event : .reminder }
}

@MainActor
@Observable
final class AgendaToolsStore {
    struct EventItem: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String
    }

    struct ListItem: Identifiable {
        let id: String
        let title: String
        let allowsChanges: Bool
    }

    struct ReminderItem: Identifiable, Sendable {
        let id: String
        let title: String
        let listID: String
        let dueDate: Date?
        let isCompleted: Bool
    }

    private let eventStore = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var reminderFetch: Any?
    private var fetchGeneration = 0
    private var isShutDown = false
    @ObservationIgnored private var visibleTool: AgendaTool?
    private var requestingAccess: Set<AgendaTool> = []

    private(set) var calendarStatus: EKAuthorizationStatus = .notDetermined
    private(set) var remindersStatus: EKAuthorizationStatus = .notDetermined
    private(set) var upcomingEvents: [EventItem] = []
    private(set) var dayEvents: [EventItem] = []
    private(set) var reminderLists: [ListItem] = []
    private(set) var reminders: [ReminderItem] = []
    private(set) var isLoadingReminders = false
    var selectedDay = Date() {
        didSet { loadCalendar() }
    }
    var selectedListID: String? {
        didSet { loadReminders() }
    }
    var errorMessage: String?
    private(set) var errorTool: AgendaTool?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func shutdown() {
        setVisible(false)
        isShutDown = true
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func status(for tool: AgendaTool) -> EKAuthorizationStatus {
        tool == .calendar ? calendarStatus : remindersStatus
    }

    func setVisible(_ visible: Bool, tool: AgendaTool? = nil) {
        guard !isShutDown else { return }
        // The old view may disappear after the new view has appeared.
        if !visible, let tool, visibleTool != tool { return }
        guard visible, let tool else {
            visibleTool = nil
            cancelReminderFetch()
            clearContent()
            return
        }
        guard visibleTool != tool else { return }
        cancelReminderFetch()
        clearContent()
        visibleTool = tool
        refresh(tool)
    }

    func refresh(_ requestedTool: AgendaTool? = nil) {
        guard !isShutDown, let visibleTool,
              requestedTool == nil || requestedTool == visibleTool else { return }
        let status = EKEventStore.authorizationStatus(for: visibleTool.entityType)
        switch visibleTool {
        case .calendar:
            calendarStatus = status
            if status == .fullAccess { loadCalendar() }
            else { upcomingEvents = []; dayEvents = [] }
        case .reminders:
            remindersStatus = status
            if status == .fullAccess { loadReminders() }
            else {
                cancelReminderFetch()
                reminderLists = []
                reminders = []
            }
        }
    }

    private func cancelReminderFetch() {
        if let reminderFetch { eventStore.cancelFetchRequest(reminderFetch) }
        reminderFetch = nil
        fetchGeneration += 1
        isLoadingReminders = false
    }

    private func clearContent() {
        upcomingEvents = []
        dayEvents = []
        reminderLists = []
        reminders = []
    }

    func requestAccess(for tool: AgendaTool, context: ToolsContext) async {
        guard !isShutDown, visibleTool == tool, status(for: tool) == .notDetermined,
              !requestingAccess.contains(tool) else { return }
        requestingAccess.insert(tool)
        defer { requestingAccess.remove(tool) }
        errorMessage = nil
        errorTool = nil
        context.beginDialog()
        defer { context.endDialog() }
        do {
            if tool == .calendar {
                _ = try await eventStore.requestFullAccessToEvents()
            } else {
                _ = try await eventStore.requestFullAccessToReminders()
            }
        } catch {
            errorMessage = error.localizedDescription
            errorTool = tool
        }
        refresh(tool)
    }

    func loadCalendar() {
        guard !isShutDown, visibleTool == .calendar, calendarStatus == .fullAccess else { return }
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let upcomingEnd = Calendar.current.date(byAdding: .day, value: 7, to: today) ?? now.addingTimeInterval(604_800)
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        upcomingEvents = events(from: now, to: upcomingEnd)
        dayEvents = events(from: dayStart, to: dayEnd)
    }

    private func events(from start: Date, to end: Date) -> [EventItem] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                EventItem(
                    id: "\(event.calendarItemIdentifier):\(event.startDate.timeIntervalSince1970)",
                    title: event.title.isEmpty ? "Untitled event" : event.title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendar: event.calendar.title
                )
            }
    }

    func loadReminders() {
        guard !isShutDown, visibleTool == .reminders, remindersStatus == .fullAccess else { return }
        cancelReminderFetch()
        let generation = fetchGeneration
        let calendars = eventStore.calendars(for: .reminder).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        reminderLists = calendars.map {
            ListItem(id: $0.calendarIdentifier, title: $0.title, allowsChanges: $0.allowsContentModifications)
        }
        if let selectedListID, !reminderLists.contains(where: { $0.id == selectedListID }) {
            self.selectedListID = nil
            return
        }
        let selectedCalendars = selectedListID.flatMap { id in
            calendars.first(where: { $0.calendarIdentifier == id }).map { [$0] }
        }
        let predicate = eventStore.predicateForReminders(in: selectedCalendars)
        isLoadingReminders = true
        reminderFetch = eventStore.fetchReminders(matching: predicate) { [weak self] fetched in
            let items: [ReminderItem] = (fetched ?? []).map { reminder in
                ReminderItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title.isEmpty ? "Untitled reminder" : reminder.title,
                    listID: reminder.calendar.calendarIdentifier,
                    dueDate: reminder.dueDateComponents.flatMap { components in
                        (components.calendar ?? Calendar.current).date(from: components)
                    },
                    isCompleted: reminder.isCompleted
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isShutDown, self.visibleTool == .reminders,
                      generation == self.fetchGeneration else { return }
                self.reminderFetch = nil
                self.reminders = items.sorted { lhs, rhs in
                    if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                    if let left = lhs.dueDate, let right = rhs.dueDate, left != right { return left < right }
                    if lhs.dueDate != nil && rhs.dueDate == nil { return true }
                    if lhs.dueDate == nil && rhs.dueDate != nil { return false }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                self.isLoadingReminders = false
            }
        }
    }

    func toggleCompletion(_ item: ReminderItem) {
        guard visibleTool == .reminders, remindersStatus == .fullAccess,
              let reminder = eventStore.calendarItem(withIdentifier: item.id) as? EKReminder,
              reminder.calendar.allowsContentModifications else { return }
        reminder.isCompleted = !reminder.isCompleted
        do {
            try eventStore.save(reminder, commit: true)
            errorMessage = nil
            errorTool = nil
            loadReminders()
        } catch {
            errorMessage = error.localizedDescription
            errorTool = .reminders
        }
    }

    func addReminder(title: String, to listID: String?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard visibleTool == .reminders, remindersStatus == .fullAccess, !trimmed.isEmpty else { return false }
        let calendar = listID.flatMap(eventStore.calendar(withIdentifier:))
            ?? eventStore.defaultCalendarForNewReminders()
            ?? eventStore.calendars(for: .reminder).first(where: \.allowsContentModifications)
        guard let calendar, calendar.allowsContentModifications else {
            errorMessage = "No writable reminder list is available."
            errorTool = .reminders
            return false
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = trimmed
        reminder.calendar = calendar
        do {
            try eventStore.save(reminder, commit: true)
            errorMessage = nil
            errorTool = nil
            loadReminders()
            return true
        } catch {
            errorMessage = error.localizedDescription
            errorTool = .reminders
            return false
        }
    }
}

struct AgendaToolsView: View {
    let tool: AgendaTool
    @Bindable var store: AgendaToolsStore
    let context: ToolsContext

    @State private var reminderTitle = ""
    @State private var showCompleted = false
    @FocusState private var reminderFieldFocused: Bool

    private let background = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let accent = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            if store.status(for: tool) == .fullAccess {
                if tool == .calendar { calendarContent } else { remindersContent }
            } else {
                accessContent
            }
            if store.errorTool == tool, let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .preferredColorScheme(.dark)
        .onAppear { store.setVisible(true, tool: tool) }
        .onDisappear { store.setVisible(false, tool: tool) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 31, height: 31)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.system(size: 15, weight: .semibold))
                Text(tool == .calendar ? "Your upcoming schedule" : "Your lists and tasks")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.status(for: tool) == .fullAccess {
                Button { store.refresh(tool) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh \(tool.title)")
                    .accessibilityLabel("Refresh \(tool.title)")
            }
        }
    }

    private var accessContent: some View {
        let status = store.status(for: tool)
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: status == .denied || status == .restricted ? "lock.slash" : tool.symbol)
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(accent.opacity(0.8))
            Text(accessTitle(for: status))
                .font(.system(size: 15, weight: .semibold))
            Text(accessDetail(for: status))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            if status == .notDetermined {
                Button("Allow \(tool.title) Access") {
                    Task { await store.requestAccess(for: tool, context: context) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            } else if status == .denied || status == .writeOnly {
                Button("Open Privacy Settings") { openPrivacySettings() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessTitle(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Connect \(tool.title)"
        case .denied: "Access is off"
        case .restricted: "Access is restricted"
        case .writeOnly: "Full access is needed"
        case .fullAccess: ""
        @unknown default: "Calendar access unavailable"
        }
    }

    private func accessDetail(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            tool == .calendar
                ? "See upcoming events and the schedule for a selected day."
                : "See your reminder lists, complete tasks, and add new reminders."
        case .denied: "Enable \(tool.title) for Knotch in Privacy & Security to use this tool."
        case .restricted: "This Mac currently restricts access to \(tool.title.lowercased())."
        case .writeOnly: "Knotch needs full access to display your \(tool.title.lowercased()). Change access in Privacy & Security."
        case .fullAccess: ""
        @unknown default: "Check Privacy & Security settings for this Mac."
        }
    }

    private func openPrivacySettings() {
        let pane = tool == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var calendarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeading("Upcoming", detail: "Next 7 days")
                if store.upcomingEvents.isEmpty {
                    emptyCard("No upcoming events", symbol: "calendar.badge.checkmark")
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.upcomingEvents) { eventRow($0) }
                    }
                }

                HStack {
                    sectionHeading("Selected day", detail: nil)
                    Spacer()
                    DatePicker("Day", selection: $store.selectedDay, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityLabel("Select calendar day")
                }
                if store.dayEvents.isEmpty {
                    emptyCard("Nothing on \(store.selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))", symbol: "sun.max")
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.dayEvents) { eventRow($0) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func eventRow(_ event: AgendaToolsStore.EventItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 33)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(event.calendar).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent)
                .fixedSize()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var remindersContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            if store.reminderLists.isEmpty {
                emptyCard("No reminder lists available", symbol: "list.bullet")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        listButton("All lists", id: nil)
                        ForEach(store.reminderLists) { list in
                            listButton(list.title, id: list.id)
                        }
                    }
                }
                .frame(height: 30)
            }

            HStack(spacing: 8) {
                TextField("New reminder", text: $reminderTitle)
                    .textFieldStyle(.plain)
                    .focused($reminderFieldFocused)
                    .onSubmit(addReminder)
                    .accessibilityLabel("New reminder title")
                Button(action: addReminder) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .disabled(reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canAddReminder)
                .accessibilityLabel("Add reminder")
            }
            .padding(10)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .disabled(!canAddReminder)

            HStack {
                sectionHeading("Open", detail: "\(store.reminders.filter { !$0.isCompleted }.count)")
                Spacer()
                Toggle("Show completed", isOn: $showCompleted)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }
            if store.isLoadingReminders {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let visible = store.reminders.filter { showCompleted || !$0.isCompleted }
                    if visible.isEmpty {
                        emptyCard("No reminders here", symbol: "checkmark.circle")
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(visible) { reminderRow($0) }
                        }
                    }
                }
            }
        }
    }

    private var canAddReminder: Bool {
        if let selectedListID = store.selectedListID {
            return store.reminderLists.first(where: { $0.id == selectedListID })?.allowsChanges == true
        }
        return store.reminderLists.contains(where: \.allowsChanges)
    }

    private func addReminder() {
        if store.addReminder(title: reminderTitle, to: store.selectedListID) {
            reminderTitle = ""
            reminderFieldFocused = true
        }
    }

    private func listButton(_ title: String, id: String?) -> some View {
        let selected = store.selectedListID == id
        return Button { store.selectedListID = id } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(selected ? accent.opacity(0.18) : .white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.4) : .white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func reminderRow(_ reminder: AgendaToolsStore.ReminderItem) -> some View {
        HStack(spacing: 10) {
            Button { store.toggleCompletion(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(reminder.isCompleted ? accent : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(store.reminderLists.first(where: { $0.id == reminder.listID })?.allowsChanges != true)
            .accessibilityLabel(reminder.isCompleted ? "Mark \(reminder.title) incomplete" : "Complete \(reminder.title)")
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let list = store.reminderLists.first(where: { $0.id == reminder.listID }) {
                        Text(list.title)
                    }
                    if let dueDate = reminder.dueDate {
                        Text("·")
                        Text(dueDate.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeading(_ title: String, detail: String?) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func emptyCard(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
