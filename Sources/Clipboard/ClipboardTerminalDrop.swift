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
