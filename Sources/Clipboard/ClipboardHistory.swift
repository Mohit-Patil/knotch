import AppKit
import Combine
import CryptoKit

/// A local snapshot of common pasteboard representations. Terminal OSC clipboard
/// callbacks remain governed by GhosttySession's separate consent path.
struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable { case text, link, richText, image, files }

    var id = UUID()
    var kind: Kind
    var text: String?
    var data: Data?
    var imageType: String?
    var fileURLs: [URL]?
    var createdAt = Date()
    var pinned = false
    var dataFile: String?
    var textFile: String?
    var textPreview: String?
    var contentDigest: String?
    var payloadBytes: Int?
    // Runtime-only location: persisted filenames must match the entry UUID.
    var payloadDirectory: URL?

    enum CodingKeys: String, CodingKey {
        case id, kind, text, data, imageType, fileURLs, createdAt, pinned
        case dataFile, textFile, textPreview, contentDigest, payloadBytes
    }

    var validPayloadNames: Bool {
        (dataFile == nil || dataFile == id.uuidString + ".data")
            && (textFile == nil || textFile == id.uuidString + ".text")
    }

    func prepared() -> ClipboardEntry {
        var entry = self
        entry.textPreview = text.map { String($0.prefix(640)) }
        entry.payloadBytes = (data?.count ?? 0) + (text?.utf8.count ?? 0)
        let dataHash = SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
        let textHash = SHA256.hash(data: Data((text ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        entry.contentDigest = dataHash + textHash
        return entry
    }

    mutating func adoptPayload(from stored: ClipboardEntry) {
        data = stored.data
        text = stored.text
        dataFile = stored.dataFile
        textFile = stored.textFile
        payloadDirectory = stored.payloadDirectory
    }

    var label: String {
        switch kind {
        case .text, .link, .richText: return String((text ?? textPreview ?? "").prefix(160))
        case .image: return "Image"
        case .files:
            let names = fileURLs?.map(\.lastPathComponent) ?? []
            return names.count == 1 ? names[0] : "\(names.count) files"
        }
    }

    func hasSameContent(as other: ClipboardEntry) -> Bool {
        kind == other.kind && imageType == other.imageType && fileURLs == other.fileURLs
            && (contentDigest != nil && other.contentDigest != nil
                ? contentDigest == other.contentDigest
                : text == other.text && data == other.data)
    }
}

@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused = false
    @Published private(set) var persistsHistory: Bool

    private let pasteboard: NSPasteboard
    private let storage: ClipboardStorage?
    @Published private(set) var isLoading = false
    @Published private(set) var storageFailed = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var pendingActions: [() -> Void] = []
    private var needsSave = false
    private var observing = false
    private var copyRevision = 0
    private let maximumPayloadBytes = 128 * 1024 * 1024
    private var lastChangeCount: Int
    private var timer: Timer?
    private let maximumEntries = 50
    private let maximumImageBytes = 4 * 1024 * 1024
    private let maximumTextBytes = 100 * 1024

    init(pasteboard: NSPasteboard = .general, storageURL: URL? = nil, persistsHistory: Bool = true) {
        self.pasteboard = pasteboard
        self.storage = storageURL.map(ClipboardStorage.init(indexURL:))
        self.persistsHistory = persistsHistory
        lastChangeCount = pasteboard.changeCount
        if let storage {
            isLoading = true
            loadTask = Task { [weak self] in
                do {
                    if persistsHistory {
                        let loaded = try await storage.load()
                        guard let self else { return }
                        self.entries = loaded.entries
                        self.storageFailed = loaded.migrationFailed
                    } else {
                        _ = try await storage.save([], persistent: false)
                    }
                } catch { self?.storageFailed = true }
                guard let self else { return }
                self.isLoading = false
                let actions = self.pendingActions
                self.pendingActions.removeAll()
                for action in actions { action() }
            }
        }
    }

    func start() {
        observing = true
        startTimer()
    }

    private func startTimer() {
        guard observing, !isPaused, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureChange() }
        }
        timer?.tolerance = 0.1
    }

    func stop() { observing = false; timer?.invalidate(); timer = nil }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused { timer?.invalidate(); timer = nil }
        else {
            // Never backfill content copied while capture was paused.
            lastChangeCount = pasteboard.changeCount
            startTimer()
        }
    }

    func setPersistsHistory(_ enabled: Bool) {
        whenLoaded { [self] in
            guard persistsHistory != enabled else { return }
            persistsHistory = enabled
            save()
        }
    }

    private func whenLoaded(_ action: @escaping () -> Void) {
        if isLoading { pendingActions.append(action) }
        else { action() }
    }

    func captureChange() {
        guard !isPaused else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !isPaused, let entry = Self.readEntry(from: pasteboard,
                                                    maximumTextBytes: maximumTextBytes,
                                                    maximumImageBytes: maximumImageBytes) else { return }
        let prepared = entry.prepared()
        whenLoaded { [self] in insert(prepared) }
    }

    private func insert(_ entry: ClipboardEntry) {
        if let duplicate = entries.firstIndex(where: { $0.hasSameContent(as: entry) }) {
            var existing = entries.remove(at: duplicate)
            existing.createdAt = Date()
            entries.insert(existing, at: 0)
        } else { entries.insert(entry, at: 0) }
        trimAndSave()
    }

    func resolve(_ entry: ClipboardEntry) async throws -> ClipboardEntry {
        if let storage { return try await storage.resolve(entry) }
        return entry
    }

    func copy(_ entry: ClipboardEntry) async {
        copyRevision += 1
        let revision = copyRevision
        let boardRevision = pasteboard.changeCount
        guard let entry = try? await resolve(entry), revision == copyRevision,
              pasteboard.changeCount == boardRevision,
              entries.contains(where: { $0.id == entry.id }) else { return }
        // Missing payloads never erase the current clipboard.
        pasteboard.clearContents()
        switch entry.kind {
        case .text, .link:
            if let text = entry.text { pasteboard.setString(text, forType: .string) }
        case .richText:
            let item = NSPasteboardItem()
            if let text = entry.text { item.setString(text, forType: .string) }
            if let data = entry.data { item.setData(data, forType: .rtf) }
            pasteboard.writeObjects([item])
        case .image:
            if let data = entry.data, let imageType = entry.imageType {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(imageType))
            }
        case .files:
            if let urls = entry.fileURLs { pasteboard.writeObjects(urls as [NSPasteboardWriting]) }
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// A drop is saved to Knotch's history without replacing the user's
    /// system clipboard. The returned entry is the one retained after dedupe.
    func addDropped(_ entry: ClipboardEntry) -> ClipboardEntry? {
        guard entry.kind == .image || entry.kind == .files else { return nil }
        if entry.kind == .image {
            guard let data = entry.data, !data.isEmpty,
                  data.count <= maximumImageBytes else { return nil }
        } else {
            guard let urls = entry.fileURLs, !urls.isEmpty, urls.count <= 20,
                  urls.allSatisfy(\.isFileURL) else { return nil }
        }
        let prepared = entry.prepared()
        whenLoaded { [self] in insert(prepared) }
        return entries.first(where: { $0.hasSameContent(as: prepared) }) ?? (isLoading ? prepared : nil)
    }

    func togglePinned(_ id: UUID) {
        whenLoaded { [self] in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].pinned.toggle()
            save()
        }
    }

    func remove(_ id: UUID) {
        whenLoaded { [self] in entries.removeAll { $0.id == id }; save() }
    }

    func clearUnpinned() {
        whenLoaded { [self] in entries.removeAll { !$0.pinned }; save() }
    }

    func clearAll() {
        whenLoaded { [self] in
            entries.removeAll()
            Task { await ClipboardThumbnails.shared.clear() }
            save()
        }
    }

    private func trimAndSave() {
        while entries.count > maximumEntries
                || entries.reduce(0, { $0 + ($1.payloadBytes ?? 0) }) > maximumPayloadBytes {
            guard let index = entries.lastIndex(where: { !$0.pinned }) else { break }
            entries.remove(at: index)
        }
        save()
    }

    private static func readEntry(from board: NSPasteboard, maximumTextBytes: Int,
                                  maximumImageBytes: Int) -> ClipboardEntry? {
        let types = board.types ?? []
        // Password managers and other apps can mark a pasteboard item as
        // transient or concealed. Do not add those representations to history.
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                        "org.nspasteboard.AutoGeneratedType"]
        guard !types.contains(where: { excluded.contains($0.rawValue) }) else { return nil }

        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.count <= 20 {
            return ClipboardEntry(kind: .files, fileURLs: urls)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), !data.isEmpty,
               data.count <= maximumImageBytes, NSImage(data: data) != nil {
                return ClipboardEntry(kind: .image, data: data, imageType: type.rawValue)
            }
        }
        guard let text = board.string(forType: .string), !text.isEmpty,
              text.utf8.count <= maximumTextBytes else { return nil }
        if let rich = board.data(forType: .rtf), !rich.isEmpty,
           rich.count <= maximumImageBytes {
            return ClipboardEntry(kind: .richText, text: text, data: rich)
        }
        let scheme = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        return ClipboardEntry(kind: scheme == "https" || scheme == "http" ? .link : .text,
                              text: text)
    }

    /// One writer drains the newest snapshot. Mutations during an in-flight
    /// commit coalesce; completion only swaps payload backing, never UI metadata.
    private func save() {
        guard let storage else { return }
        needsSave = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            while self.needsSave {
                self.needsSave = false
                let snapshot = self.entries
                let persistent = self.persistsHistory
                do {
                    let stored = try await storage.save(snapshot, persistent: persistent)
                    let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                    var compacted = self.entries
                    for index in compacted.indices {
                        if let entry = byID[compacted[index].id] {
                            compacted[index].adoptPayload(from: entry)
                        }
                    }
                    if compacted != self.entries { self.entries = compacted }
                    if self.storageFailed { self.storageFailed = false }
                } catch {
                    // Keep inline payloads if disk storage fails; never discard
                    // the user's only copy or report a failed commit as saved.
                    self.storageFailed = true
                }
            }
            self.saveTask = nil
        }
    }

    func waitUntilSettled() async {
        await loadTask?.value
        await saveTask?.value
    }
}
