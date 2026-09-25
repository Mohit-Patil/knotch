import AppKit
import Combine

/// A local snapshot of common pasteboard representations. Terminal OSC clipboard
/// callbacks remain governed by GhosttySession's separate consent path.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, richText, image, files }

    var id = UUID()
    var kind: Kind
    var text: String?
    var data: Data?
    var imageType: String?
    var fileURLs: [URL]?
    var createdAt = Date()
    var pinned = false

    var label: String {
        switch kind {
        case .text, .link, .richText: return String(text?.prefix(160) ?? "")
        case .image: return "Image"
        case .files:
            let names = fileURLs?.map(\.lastPathComponent) ?? []
            return names.count == 1 ? names[0] : "\(names.count) files"
        }
    }

    func hasSameContent(as other: ClipboardEntry) -> Bool {
        kind == other.kind && text == other.text && data == other.data
            && imageType == other.imageType && fileURLs == other.fileURLs
    }
}

@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused = false
    @Published private(set) var persistsHistory: Bool

    private let pasteboard: NSPasteboard
    private let storageURL: URL?
    private var lastChangeCount: Int
    private var timer: Timer?
    private let maximumEntries = 50
    private let maximumImageBytes = 4 * 1024 * 1024
    private let maximumTextBytes = 100 * 1024

    init(pasteboard: NSPasteboard = .general, storageURL: URL? = nil, persistsHistory: Bool = true) {
        self.pasteboard = pasteboard
        self.storageURL = storageURL
        self.persistsHistory = persistsHistory
        lastChangeCount = pasteboard.changeCount
        if persistsHistory { load() }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureChange() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        // Never backfill content copied while capture was paused.
        if !paused { lastChangeCount = pasteboard.changeCount }
    }

    func setPersistsHistory(_ enabled: Bool) {
        guard persistsHistory != enabled else { return }
        persistsHistory = enabled
        if enabled { save() }
        else if let storageURL { try? FileManager.default.removeItem(at: storageURL) }
    }

    func captureChange() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !isPaused, let entry = Self.readEntry(from: pasteboard,
                                                    maximumTextBytes: maximumTextBytes,
                                                    maximumImageBytes: maximumImageBytes) else { return }
        if let duplicate = entries.firstIndex(where: { $0.hasSameContent(as: entry) }) {
            var existing = entries.remove(at: duplicate)
            existing.createdAt = Date()
            entries.insert(existing, at: 0)
        } else {
            entries.insert(entry, at: 0)
        }
        trimAndSave()
    }

    func copy(_ entry: ClipboardEntry) {
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
        if let index = entries.firstIndex(where: { $0.hasSameContent(as: entry) }) {
            var existing = entries.remove(at: index)
            existing.createdAt = Date()
            entries.insert(existing, at: 0)
        } else {
            entries.insert(entry, at: 0)
        }
        trimAndSave()
        return entries.first
    }

    func togglePinned(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearUnpinned() {
        entries.removeAll { !$0.pinned }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    private func trimAndSave() {
        if entries.count > maximumEntries {
            let pins = entries.filter(\.pinned)
            let recent = entries.filter { !$0.pinned }.prefix(max(0, maximumEntries - pins.count))
            let keep = Set((pins + recent).map(\.id))
            entries.removeAll { !keep.contains($0.id) }
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

    private func load() {
        guard let storageURL,
              let size = try? storageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 256 * 1024 * 1024,
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(maximumEntries))
    }

    private func save() {
        guard persistsHistory, let storageURL else { return }
        do {
            let folder = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: folder.path)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: storageURL.path)
        } catch {
            // Clipboard capture remains usable in memory if local storage fails.
        }
    }
}
