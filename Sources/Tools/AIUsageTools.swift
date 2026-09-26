import AppKit
import Foundation
import Observation
import SwiftUI

// Usage is deliberately refreshed on demand. The only automatic read is the
// authenticated Codex CLI's public app-server request; no credential files or
// other agents' configuration are inspected.
@MainActor
@Observable
final class AIUsageToolsStore {
    enum CodexState {
        case idle
        case loading
        case loaded([CodexLimit])
        case unavailable(String)
    }

    private(set) var codexState: CodexState = .idle
    private(set) var lastRefresh: Date?
    private(set) var manualSnapshots: [AIUsageProvider: ManualUsageSnapshot] = [:]

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var runner: CodexUsageRunner?
    @ObservationIgnored private let storageKey = "aiUsage.manualSnapshots.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([AIUsageProvider: ManualUsageSnapshot].self, from: data) {
            manualSnapshots = saved
        }
    }

    func refresh() {
        refreshTask?.cancel()
        runner?.cancel()
        let nextRunner = CodexUsageRunner()
        runner = nextRunner
        codexState = .loading
        refreshTask = Task { [weak self] in
            let result = await nextRunner.read()
            guard let self, !Task.isCancelled else { return }
            self.lastRefresh = Date()
            switch result {
            case .success(let limits):
                self.codexState = limits.isEmpty
                    ? .unavailable("Codex returned no rate-limit windows for this account.")
                    : .loaded(limits)
            case .failure(let message):
                self.codexState = .unavailable(message)
            }
            self.runner = nil
            self.refreshTask = nil
        }
    }

    func saveManual(_ snapshot: ManualUsageSnapshot, for provider: AIUsageProvider) {
        manualSnapshots[provider] = snapshot
        persistManualSnapshots()
    }

    func clearManual(for provider: AIUsageProvider) {
        manualSnapshots.removeValue(forKey: provider)
        persistManualSnapshots()
    }

    func shutdown() {
        refreshTask?.cancel()
        refreshTask = nil
        runner?.cancel()
        runner = nil
    }

    private func persistManualSnapshots() {
        guard let data = try? JSONEncoder().encode(manualSnapshots) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum AIUsageProvider: String, Codable, Hashable, Identifiable {
    case claude
    case copilot

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "GitHub Copilot" }
    var symbol: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }
    var helpURL: URL {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/cli-reference")!
        case .copilot: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference")!
        }
    }
    var guidance: String {
        switch self {
        case .claude: "Check /usage in Claude Code, then record the percentage you see."
        case .copilot: "Check your Copilot billing and usage page, then record the percentage you see. CLI /usage describes only the current session."
        }
    }
}

struct ManualUsageSnapshot: Codable, Equatable {
    let usedPercent: Int
    let observedAt: Date
    let resetsAt: Date?
}

struct CodexLimit: Sendable, Identifiable {
    let id: String
    let name: String
    let windows: [CodexWindow]
    let ordinaryUsageAllowed: Bool?
}

struct CodexWindow: Sendable, Identifiable {
    let id: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?
}

struct AIUsageToolsView: View {
    let store: AIUsageToolsStore
    @State private var editingProvider: AIUsageProvider?

    private let panel = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let card = Color(red: 0.15, green: 0.16, blue: 0.18)
    private let accent = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                header
                codexCard
                ForEach([AIUsageProvider.claude, .copilot]) { provider in
                    manualCard(for: provider)
                }
                Text("Manual entries are snapshots, not live account usage. Limits and reset times can change in the provider's own app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(panel)
        .preferredColorScheme(.dark)
        .sheet(item: $editingProvider) { provider in
            ManualUsageEditor(provider: provider,
                              existing: store.manualSnapshots[provider]) { snapshot in
                store.saveManual(snapshot, for: provider)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AI Usage")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Codex limits from its authenticated CLI. Other providers use your own observations.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(isLoading)
            .accessibilityLabel("Refresh Codex usage")
        }
    }

    private var isLoading: Bool {
        if case .loading = store.codexState { true } else { false }
    }

    private var codexCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            providerHeading("Codex", symbol: "bolt.fill", badge: "LIVE · ON REFRESH")
            switch store.codexState {
            case .idle:
                detail("Choose Refresh to read the current account's Codex rate limits.")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    detail("Reading Codex limits…")
                }
            case .unavailable(let reason):
                detail(reason)
            case .loaded(let limits):
                ForEach(limits) { limit in
                    VStack(alignment: .leading, spacing: 12) {
                        if limits.count > 1 {
                            Text(limit.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if limit.ordinaryUsageAllowed == false {
                            Label("Included usage is currently unavailable", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        ForEach(limit.windows) { window in
                            usageWindow(window)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let refreshed = store.lastRefresh {
                Text("Checked \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func usageWindow(_ window: CodexWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(windowTitle(window))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(window.usedPercent)% used")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(window.usedPercent >= 90 ? Color.orange : accent)
                        .frame(width: geometry.size.width * CGFloat(window.usedPercent) / 100)
                }
            }
            .frame(height: 6)
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func windowTitle(_ window: CodexWindow) -> String {
        guard let minutes = window.durationMinutes else { return window.id.capitalized + " window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private func manualCard(for provider: AIUsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            providerHeading(provider.title, symbol: provider.symbol, badge: "MANUAL")
            if let snapshot = store.manualSnapshots[provider] {
                HStack {
                    Text("\(snapshot.usedPercent)% used")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("Observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if let reset = snapshot.resetsAt {
                    detail("Reset you recorded: \(reset.formatted(date: .abbreviated, time: .shortened))")
                }
            } else {
                detail("Live quota unavailable through a supported noninteractive CLI interface.")
            }
            detail(provider.guidance)
            HStack(spacing: 16) {
                Button(store.manualSnapshots[provider] == nil ? "Record observed usage" : "Update observation") {
                    editingProvider = provider
                }
                .buttonStyle(.bordered)
                Link("CLI help", destination: provider.helpURL)
                    .font(.system(size: 11))
                if store.manualSnapshots[provider] != nil {
                    Button("Clear") { store.clearManual(for: provider) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func providerHeading(_ title: String, symbol: String, badge: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .frame(width: 18)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(badge)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(0.07), in: Capsule())
        }
    }

    private func detail(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.58))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ManualUsageEditor: View {
    let provider: AIUsageProvider
    let onSave: (ManualUsageSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var percentage: String
    @State private var hasReset: Bool
    @State private var resetDate: Date

    init(provider: AIUsageProvider, existing: ManualUsageSnapshot?,
         onSave: @escaping (ManualUsageSnapshot) -> Void) {
        self.provider = provider
        self.onSave = onSave
        _percentage = State(initialValue: existing.map { String($0.usedPercent) } ?? "")
        _hasReset = State(initialValue: existing?.resetsAt != nil)
        _resetDate = State(initialValue: existing?.resetsAt ?? Date().addingTimeInterval(86_400))
    }

    private var validPercentage: Int? {
        guard let value = Int(percentage.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...100).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Record \(provider.title) usage")
                .font(.system(size: 19, weight: .semibold))
            Text("Enter what you observed in the provider's app. Knotch stamps this entry with the current time.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                TextField("Used percentage (0–100)", text: $percentage)
                    .textFieldStyle(.roundedBorder)
                Text("% used")
                    .foregroundStyle(.secondary)
            }
            Toggle("I know the reset time", isOn: $hasReset)
            if hasReset {
                DatePicker("Resets", selection: $resetDate, displayedComponents: [.date, .hourAndMinute])
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save observation") {
                    guard let usedPercent = validPercentage else { return }
                    onSave(ManualUsageSnapshot(usedPercent: usedPercent,
                                               observedAt: Date(),
                                               resetsAt: hasReset ? resetDate : nil))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(validPercentage == nil)
            }
        }
        .padding(24)
        .frame(width: 390)
    }
}

private enum CodexReadResult: Sendable {
    case success([CodexLimit])
    case failure(String)
}

private final class CodexUsageRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func read() async -> CodexReadResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.readBlocking())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    private func readBlocking() -> CodexReadResult {
        guard let executable = Self.executable(named: "codex") else {
            return .failure("Codex CLI was not found in the app's PATH. Install it or launch Knotch with a PATH that includes codex.")
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["app-server", "--stdio"]
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        child.standardError = FileHandle.nullDevice

        lock.lock()
        if cancelled {
            lock.unlock()
            return .failure("Refresh cancelled.")
        }
        process = child
        lock.unlock()

        do {
            try child.run()
        } catch {
            finish(child)
            return .failure("Codex CLI could not start.")
        }

        let timeout = DispatchWorkItem { [weak self, weak child] in
            guard let self, let child else { return }
            self.lock.lock()
            let isCurrent = self.process === child
            self.lock.unlock()
            if isCurrent && child.isRunning { child.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        defer {
            timeout.cancel()
            finish(child)
        }

        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "knotch-ai-usage", "version": "1.0"]]],
            ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]]
        ]
        do {
            for request in requests {
                let encoded = try JSONSerialization.data(withJSONObject: request)
                input.fileHandleForWriting.write(encoded + Data([0x0A]))
            }
        } catch {
            return .failure("Could not request Codex usage.")
        }

        var buffered = Data()
        var totalBytes = 0
        var lineCount = 0
        while child.isRunning || !buffered.isEmpty {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            totalBytes += chunk.count
            guard totalBytes <= 262_144 else { return .failure("Codex returned too much data for a usage read.") }
            buffered.append(chunk)
            while let newline = buffered.firstIndex(of: 0x0A) {
                lineCount += 1
                guard lineCount <= 128 else { return .failure("Codex returned too many messages for a usage read.") }
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["id"] as? Int == 2 else { continue }
                if object["error"] != nil {
                    return .failure("Codex did not provide rate limits for this account.")
                }
                guard let result = object["result"] as? [String: Any] else {
                    return .failure("Codex returned an unexpected usage response.")
                }
                return .success(Self.parse(result))
            }
        }
        return .failure("Codex usage did not respond within eight seconds.")
    }

    private func finish(_ child: Process) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        lock.lock()
        if process === child { process = nil }
        lock.unlock()
    }

    private static func executable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        for folder in candidates {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func parse(_ result: [String: Any]) -> [CodexLimit] {
        let allowed = result["ordinaryUsageAllowed"] as? Bool
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let entries: [(String, [String: Any])]
        if let buckets, !buckets.isEmpty {
            entries = buckets.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            entries = [("codex", legacy)]
        } else {
            return []
        }
        return entries.compactMap { key, bucket in
            let windows: [CodexWindow] = ["primary", "secondary"].compactMap { kind in
                guard let value = bucket[kind] as? [String: Any],
                      let used = value["usedPercent"] as? Int else { return nil }
                let reset = (value["resetsAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
                return CodexWindow(id: kind, usedPercent: min(100, max(0, used)),
                                   durationMinutes: value["windowDurationMins"] as? Int,
                                   resetsAt: reset)
            }
            guard !windows.isEmpty else { return nil }
            return CodexLimit(id: key,
                              name: bucket["limitName"] as? String ?? key.capitalized,
                              windows: windows,
                              ordinaryUsageAllowed: allowed)
        }
    }
}
