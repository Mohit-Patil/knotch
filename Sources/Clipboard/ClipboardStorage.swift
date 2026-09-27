import Foundation

/// All payload/index I/O is serialized away from the UI actor. Commit the index
/// before collecting unused blobs, so a failed write leaves the previous history intact.
actor ClipboardStorage {
    struct Index: Codable {
        var version = 2
        var entries: [ClipboardEntry]
    }
    enum Failure: Error { case invalidIndex, missingPayload }
    let indexURL: URL
    let payloadDirectory: URL

    init(indexURL: URL) {
        self.indexURL = indexURL
        payloadDirectory = indexURL.deletingPathExtension().appendingPathExtension("payloads")
    }

    struct Loaded: Sendable {
        var entries: [ClipboardEntry]
        var migrationFailed = false
    }

    func load() throws -> Loaded {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return Loaded(entries: []) }
        let size = try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 280 * 1024 * 1024 else { throw Failure.invalidIndex }
        let bytes = try Data(contentsOf: indexURL)
        if let index = try? JSONDecoder().decode(Index.self, from: bytes) {
            guard index.version == 2, index.entries.count <= 50,
                  Set(index.entries.map(\.id)).count == index.entries.count else { throw Failure.invalidIndex }
            let entries = try index.entries.map { entry in
                var entry = entry
                guard entry.validPayloadNames else { throw Failure.invalidIndex }
                entry.payloadDirectory = payloadDirectory
                return entry
            }
            return Loaded(entries: entries)
        }
        // The legacy array embeds base64 payloads. Migration commits only after
        // every payload has been written; the original file survives any failure.
        let legacy = try JSONDecoder().decode([ClipboardEntry].self, from: bytes)
        let entries = Array(legacy.prefix(50)).map { $0.prepared() }
        guard Set(entries.map(\.id)).count == entries.count else { throw Failure.invalidIndex }
        do { return Loaded(entries: try save(entries, persistent: true)) }
        catch { return Loaded(entries: entries, migrationFailed: true) }
    }

    func resolve(_ entry: ClipboardEntry) throws -> ClipboardEntry {
        var value = entry
        if let name = entry.dataFile {
            guard entry.validPayloadNames, let folder = entry.payloadDirectory else { throw Failure.missingPayload }
            value.data = try read(folder.appendingPathComponent(name), limit: 4 * 1024 * 1024)
        }
        if let name = entry.textFile {
            guard entry.validPayloadNames, let folder = entry.payloadDirectory,
                  let text = String(data: try read(folder.appendingPathComponent(name), limit: 100 * 1024), encoding: .utf8)
            else { throw Failure.missingPayload }
            value.text = text
        }
        value.dataFile = nil
        value.textFile = nil
        value.payloadDirectory = nil
        return value
    }

    func save(_ entries: [ClipboardEntry], persistent: Bool) throws -> [ClipboardEntry] {
        if !persistent {
            let hydrated = try entries.map { try resolve($0) }
            // Hydrate first. Failure must not destroy the only copy of a payload.
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.removeItem(at: indexURL)
            }
            if FileManager.default.fileExists(atPath: payloadDirectory.path) {
                try FileManager.default.removeItem(at: payloadDirectory)
            }
            return hydrated
        }
        try makePrivateDirectory(indexURL.deletingLastPathComponent())
        try makePrivateDirectory(payloadDirectory)
        var compact: [ClipboardEntry] = []
        for var entry in entries {
            guard entry.validPayloadNames else { throw Failure.invalidIndex }
            if let bytes = entry.data {
                let name = entry.id.uuidString + ".data"
                try writePayload(bytes, name: name)
                entry.dataFile = name
                entry.data = nil
            }
            if let text = entry.text, text.utf8.count > 4096 {
                let name = entry.id.uuidString + ".text"
                try writePayload(Data(text.utf8), name: name)
                entry.textFile = name
                entry.text = nil
            }
            entry.payloadDirectory = payloadDirectory
            for name in [entry.dataFile, entry.textFile].compactMap({ $0 }) {
                guard FileManager.default.fileExists(atPath: payloadDirectory.appendingPathComponent(name).path)
                else { throw Failure.missingPayload }
            }
            compact.append(entry)
        }
        try privateWrite(JSONEncoder().encode(Index(entries: compact)), to: indexURL)
        let live = Set(compact.flatMap { [$0.dataFile, $0.textFile].compactMap { $0 } })
        for url in try FileManager.default.contentsOfDirectory(at: payloadDirectory, includingPropertiesForKeys: nil) {
            if !live.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
        return compact
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw Failure.invalidIndex }
        return try Data(contentsOf: url)
    }

    private func writePayload(_ bytes: Data, name: String) throws {
        let url = payloadDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try privateWrite(bytes, to: url) }
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func privateWrite(_ bytes: Data, to url: URL) throws {
        // Create the staging file with restrictive permissions before writing data.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // POSIX rename atomically replaces an existing index without a delete gap.
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
