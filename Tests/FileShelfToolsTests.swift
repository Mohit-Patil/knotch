import AppKit
import Foundation

@main struct FileShelfToolsTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("knotch-shelf-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let shelfURL = base.appendingPathComponent("shelf", isDirectory: true)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let first = FileShelfStore(storageURL: shelfURL, now: { clock })
        let imported = try first.importFiles([source])
        precondition(imported.count == 1)
        let copiedData = try Data(contentsOf: first.fileURL(for: imported[0])!)
        let sourceData = try Data(contentsOf: source)
        precondition(copiedData == Data("original".utf8))
        precondition(sourceData == Data("original".utf8))
        let secondFolder = base.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let secondSource = secondFolder.appendingPathComponent("source.txt")
        try Data("second".utf8).write(to: secondSource)
        let duplicateName = try first.importFiles([secondSource])[0]
        precondition(duplicateName.name == imported[0].name)
        precondition(first.fileURL(for: duplicateName) != first.fileURL(for: imported[0]))
        let link = base.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try first.importFiles([link])
            preconditionFailure("A symbolic link was imported")
        } catch FileShelfError.unsupported { }
        first.shutdown()

        let reloaded = FileShelfStore(storageURL: shelfURL, now: { clock })
        precondition(reloaded.items.count == 2)
        precondition(reloaded.fileURL(for: reloaded.items[0]) != nil)
        try reloaded.remove(reloaded.items[0])
        try reloaded.remove(reloaded.items[0])
        precondition(reloaded.items.isEmpty)
        let remainingSourceData = try Data(contentsOf: source)
        precondition(remainingSourceData == Data("original".utf8))
        let folder = base.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let folderItem = try reloaded.importFiles([folder])[0]
        precondition(folderItem.isDirectory && folderItem.byteCount == 6)

        let largeFolder = base.appendingPathComponent("many-files", isDirectory: true)
        try fm.createDirectory(at: largeFolder, withIntermediateDirectories: true)
        for number in 0..<400 {
            try Data("item \(number)".utf8).write(to: largeFolder.appendingPathComponent("\(number).txt"))
        }
        let backgroundImport = Task { try await reloaded.importFilesAsync([largeFolder]) }
        let deadline = Date().addingTimeInterval(5)
        while !reloaded.isBusy && Date() < deadline { await Task.yield() }
        precondition(reloaded.isBusy, "Import did not publish busy state")
        do {
            _ = try await reloaded.importFilesAsync([source])
            preconditionFailure("Overlapping import was allowed")
        } catch FileShelfError.operationInProgress { }
        let heartbeat = Task { @MainActor in true }
        let heartbeatRan = await heartbeat.value
        precondition(heartbeatRan)
        let backgroundItems = try await backgroundImport.value
        precondition(backgroundItems.count == 1 && !reloaded.isBusy)
        precondition(reloaded.importProgress == nil)
        let exportURL = base.appendingPathComponent("exported-many-files", isDirectory: true)
        try await reloaded.exportAsync(backgroundItems[0], to: exportURL)
        precondition(fm.fileExists(atPath: exportURL.appendingPathComponent("399.txt").path))
        try reloaded.remove(backgroundItems[0])
        precondition(fm.fileExists(atPath: largeFolder.appendingPathComponent("399.txt").path))

        try reloaded.setRetention(.oneDay)
        clock.addTimeInterval(86_401)
        reloaded.shutdown()
        let expired = FileShelfStore(storageURL: shelfURL, now: { clock })
        precondition(expired.items.isEmpty)
        precondition(fm.fileExists(atPath: folder.path))
        expired.shutdown()
        let indexURL = shelfURL.appendingPathComponent("index.json")
        try Data("broken index".utf8).write(to: indexURL)
        let unreadable = FileShelfStore(storageURL: shelfURL, now: { clock })
        do {
            _ = try unreadable.importFiles([source])
            preconditionFailure("Unreadable index was overwritten")
        } catch FileShelfError.unreadableIndex { }
        let preservedIndex = try Data(contentsOf: indexURL)
        precondition(preservedIndex == Data("broken index".utf8))
        unreadable.shutdown()
        print("File Shelf tools tests passed")
    }
}
