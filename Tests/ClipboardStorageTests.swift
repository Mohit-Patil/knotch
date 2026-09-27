import AppKit
import Foundation
import ImageIO

@main
struct ClipboardStorageTests {
    @MainActor static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-storage-tests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        let url = base.appendingPathComponent("history.json")
        let blob = Data(repeating: 0x37, count: 1024 * 1024)
        let longText = String(repeating: "Long text. ", count: 4000)
        var image = ClipboardEntry(kind: .image, data: blob, imageType: "public.png")
        image.pinned = true
        let rich = ClipboardEntry(kind: .richText, text: longText, data: Data("{\\rtf1 fixture}".utf8))
        // Exact legacy JSON representation: no payload references, digest, or index wrapper.
        let legacy = try JSONEncoder().encode([image, rich])
        try legacy.write(to: url)
        let history = ClipboardHistory(pasteboard: board, storageURL: url)
        await history.waitUntilSettled()
        check(history.entries.count == 2 && history.entries[0].id == image.id && history.entries[0].pinned, "Migration preserves identity, order and pins")
        check(history.entries.allSatisfy { $0.data == nil } && history.entries[1].text == nil, "Payload bytes leave the in-memory model")
        let migrated = try await history.resolve(history.entries[0])
        check(migrated.data == blob, "Migration preserves exact image bytes")
        let migratedRich = try await history.resolve(history.entries[1])
        check(migratedRich.text == longText && migratedRich.data == rich.data, "Large text and RTF resolve exactly")
        check(history.entries[1].label == String(longText.prefix(160)), "Preview remains available without loading text")
        check((try Data(contentsOf: url)).count < 4096, "Index contains metadata, not base64 payloads")
        let directory = url.deletingPathExtension().appendingPathExtension("payloads")
        let imageURL = directory.appendingPathComponent(image.id.uuidString + ".data")
        let stamp = try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        history.togglePinned(image.id)
        await history.waitUntilSettled()
        check(try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp, "Pin does not rewrite the payload")
        let mode = try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "Payload is owner-only")
        check((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Payload directory is owner-only")
        await history.copy(history.entries[0])
        check(board.data(forType: .png) == blob, "Copy resolves image from disk")
        await history.copy(history.entries[1])
        check(board.string(forType: .string) == longText && board.data(forType: .rtf) == rich.data, "Copy restores full large text and rich representation")
        _ = history.addDropped(ClipboardEntry(kind: .image, data: blob, imageType: "public.png"))
        check(history.entries.count == 2 && history.entries[0].id == image.id, "Disk entries deduplicate without loading payloads")
        await history.waitUntilSettled()
        let reloaded = ClipboardHistory(pasteboard: board, storageURL: url)
        await reloaded.waitUntilSettled()
        check(reloaded.entries.count == 2 && reloaded.entries.allSatisfy { $0.data == nil }, "Reload only loads metadata")
        history.setPersistsHistory(false)
        await history.waitUntilSettled()
        check(!FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: directory.path), "Disabling persistence removes index and blobs")
        check(history.entries[0].data == blob && history.entries[1].text == longText, "Disabling persistence preserves current in-memory history")
        history.setPersistsHistory(true)
        history.clearAll()
        await history.waitUntilSettled()
        check(try history.entries.isEmpty && FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Enable followed by clear cannot resurrect payloads")
        for i in 0..<20 {
            _ = history.addDropped(ClipboardEntry(kind: .image, data: Data(repeating: UInt8(i), count: 65536), imageType: "public.png"))
            if i % 2 == 0 { await Task.yield() }
        }
        history.setPersistsHistory(false)
        history.setPersistsHistory(true)
        history.clearAll()
        await history.waitUntilSettled()
        let empty = ClipboardHistory(pasteboard: board, storageURL: url)
        await empty.waitUntilSettled()
        check(empty.entries.isEmpty, "Rapid queued mutations and toggles finish at the latest state")
        _ = history.addDropped(image)
        await history.waitUntilSettled()
        try FileManager.default.removeItem(at: imageURL)
        board.clearContents()
        board.setString("keep existing clipboard", forType: .string)
        await history.copy(history.entries[0])
        check(board.string(forType: .string) == "keep existing clipboard", "Missing payload does not clear the clipboard")
        history.clearAll()
        await history.waitUntilSettled()
        // A capture made while loading is replayed after loading; a following clear wins.
        try legacy.write(to: url)
        let loading = ClipboardHistory(pasteboard: board, storageURL: url)
        board.clearContents(); board.setString("captured during load", forType: .string)
        loading.captureChange()
        loading.clearAll()
        await loading.waitUntilSettled()
        check(loading.entries.isEmpty, "Clear during migration is ordered after loading/capture")
        // Simulate an unwritable destination without changing user permissions.
        let blocker = base.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let failed = ClipboardHistory(pasteboard: board, storageURL: blocker.appendingPathComponent("history.json"))
        await failed.waitUntilSettled()
        _ = failed.addDropped(image)
        await failed.waitUntilSettled()
        check(failed.storageFailed && failed.entries.first?.data == blob, "Write failure retains the only payload copy in RAM")
        let memory = ClipboardHistory(pasteboard: board, storageURL: base.appendingPathComponent("disabled.json"), persistsHistory: false)
        _ = memory.addDropped(image)
        await memory.waitUntilSettled()
        check(memory.entries.first?.data == blob && !FileManager.default.fileExists(atPath: base.appendingPathComponent("disabled.json").path), "Disabled persistence never writes captured payloads")
        memory.start(); memory.setPaused(true)
        board.clearContents(); board.setString("paused", forType: .string)
        try? await Task.sleep(for: .milliseconds(650))
        memory.setPaused(false)
        try? await Task.sleep(for: .milliseconds(650))
        memory.stop()
        check(memory.entries.count == 1, "Resume does not backfill paused content")
        // Failed migration must leave both the legacy file and usable RAM entries.
        let migrationURL = base.appendingPathComponent("migration-failure.json")
        try legacy.write(to: migrationURL)
        try Data().write(to: migrationURL.deletingPathExtension().appendingPathExtension("payloads"))
        let migration = ClipboardHistory(pasteboard: board, storageURL: migrationURL)
        await migration.waitUntilSettled()
        check(migration.storageFailed && migration.entries.first?.data == blob,
              "Migration failure keeps legacy payloads available in RAM")
        check(try Data(contentsOf: migrationURL) == legacy, "Failed migration leaves original history untouched")
        let quota = ClipboardHistory(pasteboard: board, persistsHistory: false)
        let pinned = ClipboardEntry(kind: .image, data: Data(repeating: 255, count: 4 * 1024 * 1024), imageType: "public.png")
        _ = quota.addDropped(pinned)
        quota.togglePinned(pinned.id)
        for i in 0..<34 {
            _ = quota.addDropped(ClipboardEntry(kind: .image, data: Data(repeating: UInt8(i), count: 4 * 1024 * 1024), imageType: "public.png"))
        }
        check(quota.entries.reduce(0, { $0 + ($1.payloadBytes ?? 0) }) <= 128 * 1024 * 1024
              && quota.entries.contains { $0.id == pinned.id && $0.pinned }, "Byte budget evicts oldest unpinned payloads")
        quota.clearAll()
        for i in 0..<55 {
            board.clearContents(); board.setString("entry \(i)", forType: .string)
            quota.captureChange()
        }
        check(quota.entries.count == 50 && quota.entries.first?.text == "entry 54", "Entry count remains bounded")
        let disabledURL = base.appendingPathComponent("disabled-at-launch.json")
        try legacy.write(to: disabledURL)
        let disabledAtLaunch = ClipboardHistory(pasteboard: board, storageURL: disabledURL, persistsHistory: false)
        await disabledAtLaunch.waitUntilSettled()
        check(disabledAtLaunch.entries.isEmpty && !FileManager.default.fileExists(atPath: disabledURL.path),
              "Launching with persistence disabled removes leftover persistent history")
        // A large source must decode to a bounded preview rather than original pixels.
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pixels = context.makeImage()!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixels, nil)
        precondition(CGImageDestinationFinalize(destination))
        let thumbnailEntry = ClipboardEntry(kind: .image, data: encoded as Data, imageType: "public.png")
        let thumb = await ClipboardThumbnails.shared.image(for: thumbnailEntry)
        check(thumb != nil && max(thumb!.width, thumb!.height) <= 420, "Image thumbnails decode at bounded pixel dimensions")
        print("Passed \(checks) clipboard storage checks")
    }
}
