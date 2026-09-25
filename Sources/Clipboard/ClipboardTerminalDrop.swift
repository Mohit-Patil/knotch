import AppKit

/// A drag carries only this app-owned identifier. The destination resolves the
/// entry from live history instead of trusting arbitrary dragged text as a path.
enum ClipboardTerminalDrop {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.personal.Knotch.clipboard-entry-id")

    static func entryID(from board: NSPasteboard) -> UUID? {
        guard let text = board.string(forType: pasteboardType) else { return nil }
        return UUID(uuidString: text)
    }

    static func needsConfirmation(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 10 || scalar.value == 13
                || scalar.value < 32 && scalar.value != 9
                || scalar.value == 127
        }
    }

    /// Matches Ghostty's file-drop convention: insert escaped paths as paste
    /// text. Never append Return or interpret a path as an app command.
    static func escapedPath(_ path: String) -> String? {
        guard !path.isEmpty, !needsConfirmation(path) else { return nil }
        let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = ""
        for character in path {
            if escapeCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// External drags are decoded while AppKit's drag pasteboard is still valid.
/// Floating screenshot thumbnails commonly deliver a file promise rather than
/// a file URL, so keep the receiver alive until it writes the image.
enum ExternalTerminalDrop {
    enum Content {
        case files([URL])
        case image(Data, NSPasteboard.PasteboardType)
        case promises([NSFilePromiseReceiver])
    }

    static var draggedTypes: [NSPasteboard.PasteboardType] {
        let direct: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        return direct + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func canAccept(_ board: NSPasteboard) -> Bool {
        board.availableType(from: draggedTypes) != nil
    }

    static func content(from board: NSPasteboard) -> Content? {
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.count <= 20, urls.allSatisfy(\.isFileURL) {
            return .files(urls)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), !data.isEmpty, data.count <= 4 * 1024 * 1024,
               NSImage(data: data) != nil {
                return .image(data, type)
            }
        }
        if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, promises.count <= 20 {
            return .promises(promises)
        }
        return nil
    }

    static func image(from data: Data) -> ClipboardEntry? {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let image = NSImage(data: data) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
            return ClipboardEntry(kind: .image, data: data,
                                  imageType: NSPasteboard.PasteboardType.png.rawValue)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= 4 * 1024 * 1024 else { return nil }
        return ClipboardEntry(kind: .image, data: png,
                              imageType: NSPasteboard.PasteboardType.png.rawValue)
    }

    static func image(at url: URL) -> ClipboardEntry? {
        guard url.isFileURL, !url.hasDirectoryPath,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data)
    }
}

/// Images have no general terminal-paste encoding. A drop creates a private
/// temporary image and inserts its shell-escaped path. The directory is removed
/// when this app process quits, at which point its terminal sessions also end.
@MainActor
final class ClipboardImageExport {
    private let folder: URL

    init(base: URL = FileManager.default.temporaryDirectory,
         processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        folder = base.appendingPathComponent("Knotch-Clipboard-Drops-\(processID)", isDirectory: true)
    }

    func path(for entry: ClipboardEntry) throws -> String {
        guard entry.kind == .image, let data = entry.data,
              let imageType = entry.imageType,
              imageType == NSPasteboard.PasteboardType.png.rawValue
                || imageType == NSPasteboard.PasteboardType.tiff.rawValue else {
            throw DropError.unsupportedImage
        }
        let file = folder.appendingPathComponent("\(entry.id.uuidString).\(imageType == NSPasteboard.PasteboardType.png.rawValue ? "png" : "tiff")")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return file.path
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    enum DropError: LocalizedError {
        case unsupportedImage
        var errorDescription: String? { "This image cannot be inserted into the terminal." }
    }
}
