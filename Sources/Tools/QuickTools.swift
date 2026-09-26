import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

enum QuickTool: String, CaseIterable, Identifiable {
    case shortcuts = "Shortcuts"
    case emoji = "Emoji"
    case converter = "Convert"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .shortcuts: "bolt.fill"
        case .emoji: "face.smiling"
        case .converter: "arrow.left.arrow.right"
        }
    }
}

enum ConversionCategory: String, CaseIterable, Identifiable {
    case length = "Length"
    case weight = "Weight"
    case temperature = "Temperature"
    case volume = "Volume"
    case area = "Area"
    case speed = "Speed"
    case currency = "Currency"

    var id: Self { self }

    var units: [ConversionUnit] {
        switch self {
        case .length: [
            .init("Meters", "m", 1), .init("Kilometers", "km", 1_000),
            .init("Centimeters", "cm", 0.01), .init("Millimeters", "mm", 0.001),
            .init("Miles", "mi", 1_609.344), .init("Yards", "yd", 0.9144),
            .init("Feet", "ft", 0.3048), .init("Inches", "in", 0.0254)
        ]
        case .weight: [
            .init("Kilograms", "kg", 1), .init("Grams", "g", 0.001),
            .init("Milligrams", "mg", 0.000001), .init("Pounds", "lb", 0.45359237),
            .init("Ounces", "oz", 0.028349523125), .init("Metric tons", "t", 1_000)
        ]
        case .temperature: [
            .init("Celsius", "°C", 1), .init("Fahrenheit", "°F", 1),
            .init("Kelvin", "K", 1)
        ]
        case .volume: [
            .init("Liters", "L", 1), .init("Milliliters", "mL", 0.001),
            .init("Cubic meters", "m³", 1_000), .init("US gallons", "gal", 3.785411784),
            .init("US fluid ounces", "fl oz", 0.0295735295625),
            .init("US cups", "cup", 0.2365882365)
        ]
        case .area: [
            .init("Square meters", "m²", 1), .init("Square kilometers", "km²", 1_000_000),
            .init("Square centimeters", "cm²", 0.0001),
            .init("Square feet", "ft²", 0.09290304),
            .init("Acres", "ac", 4_046.8564224), .init("Hectares", "ha", 10_000),
            .init("Square miles", "mi²", 2_589_988.110336)
        ]
        case .speed: [
            .init("Meters per second", "m/s", 1),
            .init("Kilometers per hour", "km/h", 1 / 3.6),
            .init("Miles per hour", "mph", 0.44704),
            .init("Knots", "kn", 0.5144444444444445),
            .init("Feet per second", "ft/s", 0.3048)
        ]
        case .currency: [
            .init("US dollar", "USD", 1), .init("Euro", "EUR", 1),
            .init("British pound", "GBP", 1), .init("Indian rupee", "INR", 1),
            .init("Japanese yen", "JPY", 1), .init("Canadian dollar", "CAD", 1),
            .init("Australian dollar", "AUD", 1), .init("Swiss franc", "CHF", 1)
        ]
        }
    }
}

struct ConversionUnit: Identifiable {
    let name: String
    let symbol: String
    let factor: Double
    var id: String { symbol }

    init(_ name: String, _ symbol: String, _ factor: Double) {
        self.name = name
        self.symbol = symbol
        self.factor = factor
    }
}

private struct ExchangeRate: Decodable, Sendable {
    let date: String
    let base: String
    let quote: String
    let rate: Double
}

@MainActor @Observable
final class QuickToolsStore {
    var shortcuts: [String] = []
    var shortcutsLoading = false
    var shortcutsLoaded = false
    var shortcutsError: String?
    var runningShortcut: String?
    var shortcutResult: String?

    var category: ConversionCategory = .length
    var amount = "1"
    var sourceIndex = 0
    var targetIndex = 1
    var exchangeRate: Double?
    var exchangeRateDate: String?
    var exchangeRatePair: String?
    var exchangeRateError: String?
    var exchangeRateLoading = false
    @ObservationIgnored private let shortcutsRunner = ShortcutsRunner()
    @ObservationIgnored private var runningShortcutID: UUID?
    @ObservationIgnored private var exchangeRateTask: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false
    private var rateRequestID = UUID()

    init() {}

    func refreshShortcutsIfNeeded() {
        if !shortcutsLoaded && !shortcutsLoading { refreshShortcuts() }
    }

    func refreshShortcuts() {
        guard !shortcutsLoading, !isShutDown else { return }
        shortcutsLoading = true
        shortcutsError = nil
        Task {
            let result = await shortcutsRunner.execute(["list"], timeout: 10)
            guard !isShutDown else { return }
            shortcutsLoading = false
            shortcutsLoaded = true
            if result.status == 0 {
                shortcuts = result.output.split(whereSeparator: \.isNewline)
                    .map(String.init).filter { !$0.isEmpty }
                shortcutsError = nil
            } else {
                shortcutsError = result.message
            }
        }
    }

    func runShortcut(_ name: String) {
        guard shortcuts.contains(name), runningShortcut == nil, !isShutDown else { return }
        let commandID = UUID()
        runningShortcutID = commandID
        runningShortcut = name
        shortcutResult = nil
        Task {
            let result = await shortcutsRunner.execute(["run", name], id: commandID, timeout: 120)
            guard !isShutDown, runningShortcutID == commandID else { return }
            runningShortcutID = nil
            runningShortcut = nil
            if result.status == 0 {
                shortcutResult = result.output.isEmpty ? "\(name) finished." : result.output
            } else if result.status == -2 || result.status == -3 {
                shortcutResult = result.message
            } else {
                shortcutResult = "\(name) failed: \(result.message)"
            }
        }
    }

    func stopShortcut() {
        guard let runningShortcutID else { return }
        shortcutsRunner.cancel(id: runningShortcutID)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        shortcutsRunner.shutdown()
        exchangeRateTask?.cancel()
        exchangeRateTask = nil
        rateRequestID = UUID()
        runningShortcutID = nil
        runningShortcut = nil
        shortcutsLoading = false
        exchangeRateLoading = false
    }

    func selectCategory(_ newCategory: ConversionCategory) {
        category = newCategory
        sourceIndex = 0
        targetIndex = 1
        invalidateRate()
    }

    func selectSource(_ index: Int) {
        sourceIndex = index
        invalidateRate()
    }

    func selectTarget(_ index: Int) {
        targetIndex = index
        invalidateRate()
    }

    private func invalidateRate() {
        exchangeRateTask?.cancel()
        exchangeRateTask = nil
        rateRequestID = UUID()
        exchangeRate = nil
        exchangeRateDate = nil
        exchangeRatePair = nil
        exchangeRateError = nil
        exchangeRateLoading = false
    }

    var parsedAmount: Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        guard let number = formatter.number(from: amount.trimmingCharacters(in: .whitespacesAndNewlines))?.doubleValue,
              number.isFinite else { return nil }
        return number
    }

    var convertedAmount: Double? {
        guard let input = parsedAmount else { return nil }
        let units = category.units
        guard units.indices.contains(sourceIndex), units.indices.contains(targetIndex) else { return nil }
        let from = units[sourceIndex]
        let to = units[targetIndex]
        if category == .currency {
            if from.symbol == to.symbol { return input }
            guard exchangeRatePair == "\(from.symbol)/\(to.symbol)",
                  let exchangeRate else { return nil }
            return input * exchangeRate
        }
        if category == .temperature {
            let celsius: Double
            switch from.symbol {
            case "°F": celsius = (input - 32) * 5 / 9
            case "K": celsius = input - 273.15
            default: celsius = input
            }
            switch to.symbol {
            case "°F": return celsius * 9 / 5 + 32
            case "K": return celsius + 273.15
            default: return celsius
            }
        }
        return input * from.factor / to.factor
    }

    func fetchExchangeRate() {
        guard category == .currency, !isShutDown else { return }
        let units = category.units
        guard units.indices.contains(sourceIndex), units.indices.contains(targetIndex) else { return }
        let base = units[sourceIndex].symbol
        let quote = units[targetIndex].symbol
        guard base != quote else { return }
        exchangeRateTask?.cancel()
        let requestID = UUID()
        rateRequestID = requestID
        exchangeRateLoading = true
        exchangeRateError = nil
        exchangeRate = nil
        exchangeRateDate = nil
        exchangeRatePair = nil
        exchangeRateTask = Task {
            do {
                // Frankfurter v2 documents /rate/{base}/{quote} with date and rate fields.
                let url = URL(string: "https://api.frankfurter.dev/v2/rate/\(base.lowercased())/\(quote.lowercased())")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard rateRequestID == requestID else { return }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    throw RateError.unavailable(status)
                }
                let fetched = try JSONDecoder().decode(ExchangeRate.self, from: data)
                guard fetched.base.uppercased() == base,
                      fetched.quote.uppercased() == quote,
                      fetched.rate.isFinite, fetched.rate > 0 else {
                    throw RateError.invalidResponse
                }
                exchangeRate = fetched.rate
                exchangeRateDate = fetched.date
                exchangeRatePair = "\(base)/\(quote)"
            } catch {
                guard rateRequestID == requestID else { return }
                exchangeRateError = error.localizedDescription
            }
            if rateRequestID == requestID {
                exchangeRateLoading = false
                exchangeRateTask = nil
            }
        }
    }

    private enum RateError: LocalizedError {
        case unavailable(Int?)
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                return status.map { "Rate unavailable (HTTP \($0)). Try again." }
                    ?? "Rate unavailable. Try again."
            case .invalidResponse: return "The rate response was invalid. Try again."
            }
        }
    }
}

private struct ShortcutsResult: Sendable {
    let status: Int32
    let output: String
    var message: String { output.isEmpty ? "Shortcuts exited with status \(status)." : output }
}

private final class ShortcutsRunner: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "dev.personal.Knotch.shortcuts-runner", qos: .userInitiated)
    private let executableURL: URL
    private var jobs: [UUID: Job] = [:]
    private var isShutDown = false

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.executableURL = executableURL
    }

    func execute(_ arguments: [String], id: UUID = UUID(), timeout: TimeInterval) async -> ShortcutsResult {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                guard !isShutDown else {
                    continuation.resume(returning: .init(status: -2, output: "Shortcuts is shutting down."))
                    return
                }
                let job = Job(id: id, arguments: arguments, executableURL: executableURL,
                              timeout: timeout, stateQueue: stateQueue,
                              continuation: continuation) { [weak self] in
                    self?.jobs.removeValue(forKey: id)
                }
                jobs[id] = job
                job.start()
            }
        }
    }

    func cancel(id: UUID) {
        stateQueue.async { [self] in jobs[id]?.cancel(timedOut: false) }
    }

    func shutdown() {
        stateQueue.async { [self] in
            guard !isShutDown else { return }
            isShutDown = true
            for job in Array(jobs.values) { job.cancel(timedOut: false) }
        }
    }

    #if QUICKTOOLS_PROCESS_FIXTURE
    func activeJobCount() async -> Int {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in continuation.resume(returning: jobs.count) }
        }
    }
    #endif

    // All Job state is confined to stateQueue. Readability and termination callbacks dispatch to it.
    private final class Job: @unchecked Sendable {
        let id: UUID
        let arguments: [String]
        let timeout: TimeInterval
        let stateQueue: DispatchQueue
        let process = Process()
        let pipe = Pipe()
        let onExit: @Sendable () -> Void
        var continuation: CheckedContinuation<ShortcutsResult, Never>?
        var output = Data()
        var truncated = false
        var cancelRequested = false
        var finished = false

        init(id: UUID, arguments: [String], executableURL: URL, timeout: TimeInterval,
             stateQueue: DispatchQueue, continuation: CheckedContinuation<ShortcutsResult, Never>,
             onExit: @escaping @Sendable () -> Void) {
            self.id = id
            self.arguments = arguments
            self.timeout = timeout
            self.stateQueue = stateQueue
            self.continuation = continuation
            self.onExit = onExit
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
        }

        func start() {
            let readHandle = pipe.fileHandleForReading
            readHandle.readabilityHandler = { [weak self] handle in
                var bytes = [UInt8](repeating: 0, count: 4_096)
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    let chunk = Data(bytes.prefix(count))
                    self?.stateQueue.async { [weak self] in self?.append(chunk) }
                } else if count == 0 {
                    handle.readabilityHandler = nil
                }
            }
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                self?.stateQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                    self?.finish(status: status)
                }
            }
            do {
                try process.run()
                pipe.fileHandleForWriting.closeFile()
                stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.cancel(timedOut: true)
                }
            } catch {
                report(.init(status: -1, output: error.localizedDescription))
                pipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.readabilityHandler = nil
                pipe.fileHandleForReading.closeFile()
                onExit()
            }
        }

        private func append(_ chunk: Data) {
            guard continuation != nil else { return }
            let limit = 16_384
            let available = limit - output.count
            if available > 0 { output.append(chunk.prefix(available)) }
            if chunk.count > available { truncated = true }
        }

        func cancel(timedOut: Bool) {
            guard !cancelRequested, continuation != nil else { return }
            if !process.isRunning {
                finish(status: process.terminationStatus)
                return
            }
            cancelRequested = true
            let message: String
            if timedOut {
                message = arguments.first == "list"
                    ? "Could not list shortcuts within 10 seconds. Try refreshing."
                    : "Shortcuts command timed out after 120 seconds. Its actions may continue."
            } else {
                message = "Stopped the Shortcuts command. Its actions may continue."
            }
            report(.init(status: timedOut ? -3 : -2, output: message))
            if process.isRunning { process.terminate() }
            stateQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.process.isRunning else { return }
                Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
        }

        private func finish(status: Int32) {
            guard !finished else { return }
            finished = true
            if continuation != nil {
                let text = String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                report(.init(status: status, output: truncated ? text + "\n… output truncated" : text))
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForReading.closeFile()
            onExit()
        }

        private func report(_ result: ShortcutsResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}

#if QUICKTOOLS_PROCESS_FIXTURE
enum QuickToolsProcessFixture {
    static func verifyTimeoutAndCancellation() async {
        let runner = ShortcutsRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let start = Date()
        let timedOut = await runner.execute(["5"], timeout: 0.15)
        precondition(timedOut.status == -3 && Date().timeIntervalSince(start) < 2)
        let id = UUID()
        let task = Task { await runner.execute(["5"], id: id, timeout: 10) }
        try? await Task.sleep(for: .milliseconds(150))
        runner.cancel(id: id)
        let cancelled = await task.value
        precondition(cancelled.status == -2)
        await assertNoActiveJobs(runner)

        let shutdownTask = Task { await runner.execute(["5"], timeout: 10) }
        try? await Task.sleep(for: .milliseconds(150))
        runner.shutdown()
        let stoppedByShutdown = await shutdownTask.value
        precondition(stoppedByShutdown.status == -2)
        await assertNoActiveJobs(runner)
    }

    private static func assertNoActiveJobs(_ runner: ShortcutsRunner) async {
        for _ in 0..<60 {
            if await runner.activeJobCount() == 0 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Shortcuts runner retained a stopped process")
    }
}
#endif

private struct EmojiChoice: Identifiable {
    let character: String
    let name: String
    let tags: String
    var id: String { character }
    init(_ character: String, _ name: String, _ tags: String = "") {
        self.character = character; self.name = name; self.tags = tags
    }
}

private let emojiChoices: [EmojiChoice] = [
    .init("😀", "Grinning face", "happy smile"), .init("😃", "Smiling face", "happy"),
    .init("😄", "Beaming face", "happy"), .init("😁", "Grinning eyes", "happy"),
    .init("😆", "Laughing face", "funny"), .init("😂", "Tears of joy", "laugh"),
    .init("🤣", "Rolling laughter", "laugh"), .init("😊", "Smiling eyes", "happy"),
    .init("🙂", "Slight smile", "happy"), .init("😉", "Winking face", "wink"),
    .init("😍", "Heart eyes", "love"), .init("🥰", "Smiling hearts", "love"),
    .init("😘", "Blowing kiss", "love"), .init("😎", "Sunglasses", "cool"),
    .init("🤔", "Thinking face", "hmm"), .init("🫡", "Saluting face"),
    .init("🥳", "Party face", "celebrate"), .init("😴", "Sleeping face", "tired"),
    .init("😢", "Crying face", "sad"), .init("😭", "Loudly crying", "sad"),
    .init("😡", "Angry face", "mad"), .init("🤯", "Exploding head", "mind blown"),
    .init("👍", "Thumbs up", "yes approve"), .init("👎", "Thumbs down", "no"),
    .init("👏", "Clapping hands", "applause"), .init("🙌", "Raised hands", "celebrate"),
    .init("🙏", "Folded hands", "thanks please"), .init("👋", "Waving hand", "hello bye"),
    .init("🤝", "Handshake", "agreement"), .init("💪", "Flexed biceps", "strong"),
    .init("❤️", "Red heart", "love"), .init("🧡", "Orange heart", "love"),
    .init("💛", "Yellow heart", "love"), .init("💚", "Green heart", "love"),
    .init("💙", "Blue heart", "love"), .init("💜", "Purple heart", "love"),
    .init("✨", "Sparkles", "magic"), .init("⭐️", "Star", "favorite"),
    .init("🔥", "Fire", "hot"), .init("🎉", "Party popper", "celebrate"),
    .init("🎂", "Birthday cake"), .init("🎁", "Gift", "present"),
    .init("☀️", "Sun", "weather"), .init("🌙", "Moon", "night"),
    .init("🌈", "Rainbow", "weather"), .init("☁️", "Cloud", "weather"),
    .init("🌧️", "Rain cloud", "weather"), .init("❄️", "Snowflake", "weather"),
    .init("🌸", "Cherry blossom", "flower"), .init("🌱", "Seedling", "plant"),
    .init("🌍", "Globe", "earth world"), .init("🐶", "Dog", "animal"),
    .init("🐱", "Cat", "animal"), .init("🦊", "Fox", "animal"),
    .init("🐼", "Panda", "animal"), .init("🍎", "Apple", "fruit"),
    .init("🍕", "Pizza", "food"), .init("☕️", "Coffee", "drink"),
    .init("🚀", "Rocket", "space"), .init("✈️", "Airplane", "travel"),
    .init("💻", "Laptop", "computer"), .init("📱", "Phone", "mobile"),
    .init("💡", "Light bulb", "idea"), .init("🔒", "Lock", "security"),
    .init("✅", "Check mark", "done yes"), .init("❌", "Cross mark", "no cancel"),
    .init("⚠️", "Warning", "alert"), .init("❓", "Question mark", "help"),
    .init("💯", "Hundred points", "perfect"), .init("🎵", "Music note", "audio")
]

struct QuickToolsView: View {
    let tool: QuickTool
    @Bindable var store: QuickToolsStore
    @State private var shortcutQuery = ""
    @State private var emojiQuery = ""
    @State private var copiedEmoji: String?

    init(tool: QuickTool, store: QuickToolsStore) {
        self.tool = tool
        self.store = store
    }

    private let panel = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let accent = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: tool.symbol).foregroundStyle(accent)
                Text(tool.rawValue).font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            switch tool {
            case .shortcuts: shortcutsContent
            case .emoji: emojiContent
            case .converter: converterContent
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panel)
        .preferredColorScheme(.dark)
        .task(id: tool) {
            if tool == .shortcuts { store.refreshShortcutsIfNeeded() }
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run your Mac shortcuts")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { store.refreshShortcuts() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.shortcutsLoading)
                .accessibilityLabel("Refresh Shortcuts list")
            }
            searchField("Search shortcuts", text: $shortcutQuery)
            if store.shortcutsLoading {
                ProgressView("Loading shortcuts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.shortcutsError {
                ContentUnavailableView("Couldn’t load Shortcuts", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredShortcuts.isEmpty {
                ContentUnavailableView(shortcutQuery.isEmpty ? "No shortcuts found" : "No matching shortcuts",
                                       systemImage: "bolt",
                                       description: Text(shortcutQuery.isEmpty
                                        ? "Create a shortcut in the Shortcuts app, then refresh."
                                        : "Try another search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredShortcuts, id: \.self) { name in
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.circle.fill")
                                    .foregroundStyle(accent).font(.system(size: 19))
                                Text(name).lineLimit(1)
                                Spacer(minLength: 8)
                                if store.runningShortcut == name {
                                    ProgressView().controlSize(.small)
                                        .accessibilityLabel("Running shortcut \(name)")
                                    Button {
                                        store.stopShortcut()
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                    .accessibilityLabel("Stop shortcut command \(name)")
                                } else {
                                    Button {
                                        store.runShortcut(name)
                                    } label: {
                                        Label("Run", systemImage: "play.fill")
                                    }
                                    .disabled(store.runningShortcut != nil)
                                    .accessibilityLabel("Run shortcut \(name)")
                                }
                            }
                            .padding(10)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
            if let result = store.shortcutResult {
                Text(result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .accessibilityLabel("Shortcut result: \(result)")
            }
            if store.runningShortcut != nil {
                Text("Stop ends the command; actions it started may continue.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var filteredShortcuts: [String] {
        guard !shortcutQuery.isEmpty else { return store.shortcuts }
        return store.shortcuts.filter { $0.localizedCaseInsensitiveContains(shortcutQuery) }
    }

    private var emojiContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tap an emoji to copy it")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Label("More characters", systemImage: "character.book.closed")
                }
                .accessibilityLabel("Open macOS Character Viewer")
            }
            searchField("Search emoji", text: $emojiQuery)
            if filteredEmoji.isEmpty {
                ContentUnavailableView("No matching emoji", systemImage: "face.smiling",
                                       description: Text("Try another name or open Character Viewer."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                        ForEach(filteredEmoji) { choice in
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(choice.character, forType: .string)
                                copiedEmoji = choice.character
                            } label: {
                                Text(choice.character).font(.system(size: 27))
                                    .frame(maxWidth: .infinity, minHeight: 47)
                                    .background(copiedEmoji == choice.character
                                                ? accent.opacity(0.18) : .white.opacity(0.055),
                                                in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .help(choice.name)
                            .accessibilityLabel("Copy \(choice.name) emoji")
                        }
                    }
                }
            }
            if let copiedEmoji {
                Text("Copied \(copiedEmoji) to clipboard")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var filteredEmoji: [EmojiChoice] {
        let query = emojiQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return emojiChoices }
        return emojiChoices.filter {
            $0.character.contains(query) || $0.name.localizedCaseInsensitiveContains(query)
                || $0.tags.localizedCaseInsensitiveContains(query)
        }
    }

    private var converterContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A quick conversion, right where you work")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ConversionCategory.allCases) { category in
                        Button { store.selectCategory(category) } label: {
                            Text(category.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(store.category == category ? accent.opacity(0.22) : .white.opacity(0.06),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.category == category ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Amount").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("Amount", text: $store.amount)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Amount to convert")
            }
            HStack(spacing: 10) {
                unitPicker("From", selection: Binding(get: { store.sourceIndex },
                                                       set: { store.selectSource($0) }))
                Image(systemName: "arrow.right").foregroundStyle(accent)
                unitPicker("To", selection: Binding(get: { store.targetIndex },
                                                     set: { store.selectTarget($0) }))
            }
            if store.category == .currency {
                currencyControls
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Result").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if store.parsedAmount == nil {
                    Text("Enter a valid number").foregroundStyle(.secondary)
                } else if let result = store.convertedAmount, result.isFinite {
                    Text(result.formatted(.number.precision(.significantDigits(1...9)))
                         + " " + store.category.units[store.targetIndex].symbol)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .textSelection(.enabled)
                        .accessibilityLabel("Converted result")
                } else if store.category == .currency {
                    Text("Fetch a rate to convert these currencies")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Result is outside the supported range")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
        }
    }

    private func unitPicker(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Array(store.category.units.enumerated()), id: \.offset) { index, unit in
                    Text("\(unit.name) (\(unit.symbol))").tag(index)
                }
            }
            .labelsHidden()
            .accessibilityLabel("\(title) unit")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currencyControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.sourceIndex != store.targetIndex {
                Button { store.fetchExchangeRate() } label: {
                    if store.exchangeRateLoading {
                        Label("Fetching rate…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Fetch latest rate", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.exchangeRateLoading)
                .accessibilityLabel("Fetch latest exchange rate")
            }
            if let rate = store.exchangeRate, let date = store.exchangeRateDate,
               let pair = store.exchangeRatePair {
                Text("\(pair): 1 = \(rate.formatted(.number.precision(.significantDigits(1...8)))); rate date \(date) · Frankfurter")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if store.sourceIndex == store.targetIndex {
                Text("Same currency; no rate needed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = store.exchangeRateError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .accessibilityLabel("Exchange rate error: \(error)")
            }
        }
    }

    private func searchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
        }
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
}
