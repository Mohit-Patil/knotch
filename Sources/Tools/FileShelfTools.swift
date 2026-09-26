import AppKit
import Observation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileShelfItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let addedAt: Date
    let byteCount: Int64
    let isDirectory: Bool
}

enum FileShelfRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneDay, sevenDays, thirtyDays, forever

    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        case .thirtyDays: 30 * 86_400
        case .forever: nil
        }
    }
}

enum FileShelfError: LocalizedError, Sendable {
    case invalidSource(String)
    case tooManyItems
    case tooLarge
    case unsupported(String)
    case missingFile
    case destinationExists
    case airDropUnavailable
    case unreadableIndex
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidSource(let name): "Cannot import \(name). Choose a local file or folder."
        case .tooManyItems: "Import up to 20 selections and 2,000 files at a time."
        case .tooLarge: "An import cannot exceed 512 MB."
        case .unsupported(let name): "Cannot import \(name). Links, aliases, and special files are not supported."
        case .missingFile: "This shelf copy is no longer available."
        case .destinationExists: "A file already exists at that destination. Choose another name."
        case .airDropUnavailable: "AirDrop is unavailable on this Mac right now."
        case .unreadableIndex: "File Shelf's index could not be read. Its existing copies have been preserved."
        case .operationInProgress: "Wait for the current File Shelf operation to finish."
        }
    }
}

struct FileShelfImportProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case scanning, copying }
    let phase: Phase
    let completed: Int
    let total: Int

    var label: String {
        switch phase {
        case .scanning: "Checking files \(completed)/\(total)"
        case .copying: "Copying files \(completed)/\(total)"
        }
    }
}

/// Owns copies only under `storageURL`. Source URLs are inspected and copied;
/// originals are never moved, modified, or removed.
@MainActor @Observable
final class FileShelfStore {
    private struct Index: Codable {
        var retention: FileShelfRetention
        var items: [FileShelfItem]
    }

    private let fileManager = FileManager.default
    private let storageURL: URL
    private let now: () -> Date
    private var expiryTimer: Timer?
    private var indexUnreadable = false
    private var activeOperation: UUID?

    private(set) var items: [FileShelfItem] = []
    private(set) var retention: FileShelfRetention = .sevenDays
    private(set) var storageError: String?
    private(set) var isBusy = false
    private(set) var operationLabel: String?
    private(set) var importProgress: FileShelfImportProgress?

    init(storageURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.personal.Knotch", isDirectory: true)
            .appendingPathComponent("file-shelf", isDirectory: true)
        self.now = now
        do {
            try prepareStorage()
            do { try load() }
            catch { indexUnreadable = true; throw error }
            pruneExpired()
        } catch {
            storageError = "File Shelf storage could not be opened: \(error.localizedDescription)"
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneExpired() }
        }
    }

    func shutdown() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    func fileURL(for item: FileShelfItem) -> URL? {
        guard items.contains(where: { $0.id == item.id && $0.name == item.name }),
              FileShelfImportWorker.isSafeName(item.name),
              !isSymbolicLink(itemDirectory(for: item.id)) else { return nil }
        let url = itemDirectory(for: item.id).appendingPathComponent(item.name, isDirectory: item.isDirectory)
        guard fileManager.fileExists(atPath: url.path), !isSymbolicLink(url) else { return nil }
        return url
    }

    /// Synchronous fixture entrypoint. UI imports must use `importFilesAsync`.
    @discardableResult
    func importFiles(_ urls: [URL]) throws -> [FileShelfItem] {
        guard !indexUnreadable else { throw FileShelfError.unreadableIndex }
        guard !isBusy else { throw FileShelfError.operationInProgress }
        let added = try FileShelfImportWorker.importFiles(urls, into: storageURL, at: now()) { _ in }
        do { try commit(added); return added }
        catch { FileShelfImportWorker.rollback(added, in: storageURL); throw error }
    }

    /// Scans and copies on a detached worker; only the small index update and
    /// published state changes run on the main actor.
    @discardableResult
    func importFilesAsync(_ urls: [URL]) async throws -> [FileShelfItem] {
        guard !indexUnreadable else { throw FileShelfError.unreadableIndex }
        guard !isBusy else { throw FileShelfError.operationInProgress }
        let operation = UUID()
        activeOperation = operation
        isBusy = true
        operationLabel = "Importing files"
        importProgress = FileShelfImportProgress(phase: .scanning, completed: 0, total: urls.count)
        defer {
            activeOperation = nil
            isBusy = false
            operationLabel = nil
            importProgress = nil
        }

        let root = storageURL
        let date = now()
        let progressStore = self
        let added = try await Task.detached(priority: .userInitiated) {
            try FileShelfImportWorker.importFiles(urls, into: root, at: date) { progress in
                Task { @MainActor in
                    guard progressStore.activeOperation == operation else { return }
                    progressStore.importProgress = progress
                }
            }
        }.value
        do { try commit(added); return added }
        catch {
            await Task.detached(priority: .utility) {
                FileShelfImportWorker.rollback(added, in: root)
            }.value
            throw error
        }
    }

    private func commit(_ added: [FileShelfItem]) throws {
        let previous = items
        items.insert(contentsOf: added, at: 0)
        do { try save() }
        catch { items = previous; throw error }
    }

    func setRetention(_ value: FileShelfRetention) throws {
        guard !indexUnreadable else { throw FileShelfError.unreadableIndex }
        guard !isBusy else { throw FileShelfError.operationInProgress }
        guard retention != value else { return }
        let previous = retention
        retention = value
        do { try save() }
        catch { retention = previous; throw error }
        pruneExpired()
    }

    func remove(_ item: FileShelfItem) throws {
        guard !indexUnreadable else { throw FileShelfError.unreadableIndex }
        guard !isBusy else { throw FileShelfError.operationInProgress }
        guard items.contains(where: { $0.id == item.id }) else { return }
        try fileManager.removeItem(at: itemDirectory(for: item.id))
        items.removeAll { $0.id == item.id }
        try save()
    }

    func clearAll() throws {
        guard !indexUnreadable else { throw FileShelfError.unreadableIndex }
        guard !isBusy else { throw FileShelfError.operationInProgress }
        for item in items {
            try fileManager.removeItem(at: itemDirectory(for: item.id))
            items.removeAll { $0.id == item.id }
            try save()
        }
    }

    /// `destination` is supplied by a Save panel after a direct user action.
    func export(_ item: FileShelfItem, to destination: URL) throws {
        guard !isBusy else { throw FileShelfError.operationInProgress }
        guard let source = fileURL(for: item), destination.isFileURL else { throw FileShelfError.missingFile }
        guard !fileManager.fileExists(atPath: destination.path) else { throw FileShelfError.destinationExists }
        try fileManager.copyItem(at: source, to: destination)
    }

    func exportAsync(_ item: FileShelfItem, to destination: URL) async throws {
        guard !isBusy else { throw FileShelfError.operationInProgress }
        guard let source = fileURL(for: item), destination.isFileURL else { throw FileShelfError.missingFile }
        isBusy = true
        operationLabel = "Exporting \(item.name)"
        defer { isBusy = false; operationLabel = nil }
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard !manager.fileExists(atPath: destination.path) else { throw FileShelfError.destinationExists }
            try manager.copyItem(at: source, to: destination)
        }.value
    }

    private func pruneExpired() {
        guard let interval = retention.interval else { return }
        let cutoff = now().addingTimeInterval(-interval)
        var changed = false
        for item in items where item.addedAt <= cutoff {
            do {
                try fileManager.removeItem(at: itemDirectory(for: item.id))
                items.removeAll { $0.id == item.id }
                changed = true
            } catch {
                storageError = "Could not remove expired shelf copy \(item.name): \(error.localizedDescription)"
            }
        }
        if changed {
            do { try save() }
            catch { storageError = "Could not save File Shelf: \(error.localizedDescription)" }
        }
    }

    private func prepareStorage() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        guard !isSymbolicLink(storageURL) else { throw FileShelfError.invalidSource("storage directory") }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageURL.path)
    }

    private func load() throws {
        let indexURL = storageURL.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        guard !isSymbolicLink(indexURL) else { throw FileShelfError.unreadableIndex }
        let values = try indexURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 1_048_576 else { throw FileShelfError.tooLarge }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        retention = index.retention
        items = index.items.prefix(2_000).filter { item in
            guard FileShelfImportWorker.isSafeName(item.name) else { return false }
            guard !isSymbolicLink(itemDirectory(for: item.id)) else { return false }
            let url = itemDirectory(for: item.id).appendingPathComponent(item.name)
            return fileManager.fileExists(atPath: url.path) && !isSymbolicLink(url)
        }
    }

    private func save() throws {
        try prepareStorage()
        let url = storageURL.appendingPathComponent("index.json")
        let data = try JSONEncoder().encode(Index(retention: retention, items: items))
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func itemDirectory(for id: UUID) -> URL {
        storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

}

private enum FileShelfImportWorker {
    private struct ImportSize {
        var files = 0
        var bytes: Int64 = 0
    }

    private static let maxSelections = 20
    private static let maxFiles = 2_000
    private static let maxBytes: Int64 = 512 * 1024 * 1024
    private static let maxDepth = 24

    /// The worker touches source paths only to inspect and copy them. It
    /// creates and removes UUID directories only under the supplied shelf root.
    static func importFiles(_ urls: [URL], into root: URL, at date: Date,
                            report: @Sendable (FileShelfImportProgress) -> Void) throws -> [FileShelfItem] {
        guard !urls.isEmpty, urls.count <= maxSelections else { throw FileShelfError.tooManyItems }
        let manager = FileManager.default
        try prepareStorage(root, manager: manager)
        var size = ImportSize()
        var inspected: [(url: URL, isDirectory: Bool)] = []
        var access: [URL] = []
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        for (index, url) in urls.enumerated() {
            guard url.isFileURL, isSafeName(url.lastPathComponent) else {
                throw FileShelfError.invalidSource(url.lastPathComponent)
            }
            if url.startAccessingSecurityScopedResource() { access.append(url) }
            let source = url.standardizedFileURL
            let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
            if root.standardizedFileURL.path.hasPrefix(sourcePath) {
                throw FileShelfError.invalidSource(url.lastPathComponent)
            }
            try inspect(source, depth: 0, total: &size, manager: manager)
            let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            inspected.append((source, isDirectory))
            report(FileShelfImportProgress(phase: .scanning, completed: index + 1, total: urls.count))
        }

        var added: [FileShelfItem] = []
        var createdFolders: [URL] = []
        var copiedTotal = ImportSize()
        report(FileShelfImportProgress(phase: .copying, completed: 0, total: inspected.count))
        do {
            for (index, source) in inspected.enumerated() {
                let id = UUID()
                let name = source.url.lastPathComponent
                let folder = itemDirectory(for: id, in: root)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
                createdFolders.append(folder)
                let destination = folder.appendingPathComponent(name)
                try manager.copyItem(at: source.url, to: destination)
                // A source can change after preflight. Reject copied links or
                // content that grew past the aggregate bounds.
                var copied = ImportSize()
                try inspect(destination, depth: 0, total: &copied, manager: manager)
                guard copied.bytes <= maxBytes - copiedTotal.bytes else { throw FileShelfError.tooLarge }
                guard copied.files <= maxFiles - copiedTotal.files else { throw FileShelfError.tooManyItems }
                copiedTotal.bytes += copied.bytes
                copiedTotal.files += copied.files
                added.append(FileShelfItem(id: id, name: name, addedAt: date,
                                           byteCount: copied.bytes,
                                           isDirectory: source.isDirectory))
                report(FileShelfImportProgress(phase: .copying, completed: index + 1,
                                               total: inspected.count))
            }
            return added
        } catch {
            for folder in createdFolders { try? manager.removeItem(at: folder) }
            throw error
        }
    }

    static func rollback(_ items: [FileShelfItem], in root: URL) {
        let manager = FileManager.default
        for item in items { try? manager.removeItem(at: itemDirectory(for: item.id, in: root)) }
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func itemDirectory(for id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func prepareStorage(_ root: URL, manager: FileManager) throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let isLink = (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard !isLink else { throw FileShelfError.invalidSource("storage directory") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private static func inspect(_ url: URL, depth: Int, total: inout ImportSize,
                                manager: FileManager) throws {
        guard depth <= maxDepth else { throw FileShelfError.tooManyItems }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                      .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey])
        if values.isSymbolicLink == true || values.isAliasFile == true {
            throw FileShelfError.unsupported(url.lastPathComponent)
        }
        total.files += 1
        guard total.files <= maxFiles else { throw FileShelfError.tooManyItems }
        if values.isRegularFile == true {
            let bytes = Int64(values.fileSize ?? 0)
            guard bytes >= 0, bytes <= maxBytes - total.bytes else { throw FileShelfError.tooLarge }
            total.bytes += bytes
        } else if values.isDirectory == true {
            let children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            for child in children { try inspect(child, depth: depth + 1, total: &total, manager: manager) }
        } else {
            throw FileShelfError.unsupported(url.lastPathComponent)
        }
    }
}

@MainActor
struct FileShelfToolsView: View {
    let store: FileShelfStore
    let context: ToolsContext

    @State private var isDropTarget = false
    @State private var errorMessage: String?
    @State private var confirmsClear = false
    @State private var previewURL: URL?
    @State private var sharingSession: FileShelfAirDropSession?

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 9)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.white.opacity(0.72))
                Text("File Shelf")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(store.items.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer(minLength: 0)
                Menu {
                    ForEach(FileShelfRetention.allCases) { option in
                        Button(option.title) { perform { try store.setRetention(option) } }
                    }
                } label: {
                    Label(store.retention.title, systemImage: "clock")
                }
                .help("Remove shelf copies after \(store.retention.title.lowercased())")
                .disabled(store.isBusy)
                Button("Add Files", systemImage: "plus", action: chooseFiles)
                    .disabled(store.isBusy)
                if !store.items.isEmpty {
                    Button("Clear", systemImage: "trash") { confirmsClear = true }
                        .help("Remove every copy from File Shelf")
                        .disabled(store.isBusy)
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)

            if let progress = store.importProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(progress.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .controlSize(.small)
                }
            } else if let operationLabel = store.operationLabel {
                ProgressView(operationLabel)
                    .controlSize(.small)
                    .font(.system(size: 10))
            }

            if let storageError = store.storageError {
                Text(storageError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if store.items.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 23, weight: .light))
                    Text("Drop files here or choose Add Files")
                        .font(.system(size: 12))
                    Text("Knotch keeps its own copies until they expire or you remove them.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                        ForEach(store.items) { item in
                            fileCard(item)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.105, green: 0.111, blue: 0.124))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isDropTarget ? .blue.opacity(0.8) : .clear, lineWidth: 2)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .quickLookPreview($previewURL)
        .alert("File Shelf", isPresented: Binding(get: { errorMessage != nil },
                                                   set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Remove all File Shelf copies?", isPresented: $confirmsClear) {
            Button("Remove All Copies", role: .destructive) { perform { try store.clearAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Original files outside Knotch stay where they are.")
        }
        .preferredColorScheme(.dark)
    }

    private func fileCard(_ item: FileShelfItem) -> some View {
        let url = store.fileURL(for: item)
        return VStack(alignment: .leading, spacing: 7) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "questionmark.folder")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(height: 39)
            .frame(maxWidth: .infinity)
            Text(verbatim: item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 27, alignment: .topLeading)
            Text(item.addedAt, style: .date)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.44))
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .onDrag { url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
        .contextMenu {
            Button("Quick Look") { previewURL = url }
                .disabled(url == nil)
            Button("Open") { if let url { NSWorkspace.shared.open(url) } }
                .disabled(url == nil)
            Button("Reveal in Finder") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .disabled(url == nil)
            Button("Export…") { export(item) }
                .disabled(url == nil || store.isBusy)
            Button("AirDrop") { airDrop(item) }
                .disabled(url == nil || store.isBusy)
            Divider()
            Button("Remove Copy", role: .destructive) { perform { try store.remove(item) } }
                .disabled(store.isBusy)
        }
        .help("Double-click to open. Drag to export; right-click for more actions.")
        .accessibilityLabel("\(item.name), saved \(item.addedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private func chooseFiles() {
        guard !store.isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Copies"
        guard context.withDialog({ panel.runModal() }) == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            do { try await store.importFilesAsync(urls) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func export(_ item: FileShelfItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.prompt = "Export Copy"
        guard context.withDialog({ panel.runModal() }) == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do { try await store.exportAsync(item, to: destination) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func airDrop(_ item: FileShelfItem) {
        guard let url = store.fileURL(for: item) else { errorMessage = FileShelfError.missingFile.localizedDescription; return }
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [url]) else {
            errorMessage = FileShelfError.airDropUnavailable.localizedDescription
            return
        }
        context.beginDialog()
        let session = FileShelfAirDropSession(service: service) { [context] in
            context.endDialog()
            sharingSession = nil
        }
        sharingSession = session
        service.delegate = session
        service.perform(withItems: [url])
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !store.isBusy else {
            errorMessage = FileShelfError.operationInProgress.localizedDescription
            return false
        }
        guard !providers.isEmpty, providers.count <= 20 else {
            errorMessage = FileShelfError.tooManyItems.localizedDescription
            return false
        }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      let url = await droppedURL(provider) else {
                    errorMessage = "The dropped item has no file URL."
                    return
                }
                urls.append(url)
            }
            do { try await store.importFilesAsync(urls) }
            catch { errorMessage = error.localizedDescription }
        }
        return true
    }

    private func droppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = switch item {
                case let value as URL: value
                case let value as Data: URL(dataRepresentation: value, relativeTo: nil)
                default: nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private final class FileShelfAirDropSession: NSObject, NSSharingServiceDelegate {
    let service: NSSharingService
    let finish: @MainActor () -> Void

    init(service: NSSharingService, finish: @escaping @MainActor () -> Void) {
        self.service = service
        self.finish = finish
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
    }
}
