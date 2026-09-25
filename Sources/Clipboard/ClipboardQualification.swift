#if HARNESS_TESTS
import AppKit
import GhosttyKit

private final class ScreenshotPromiseFixture: NSObject, NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String { "screenshot.png" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

@MainActor
enum ClipboardQualification {
    static func run(coordinator: AppCoordinator) async {
        var records: [[String: String]] = []
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            records.append(["test": name, "result": condition ? "PASSED" : "FAILED", "detail": detail])
        }
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-clipboard-fixture-\(UUID())", isDirectory: true)
        let file = folder.appendingPathComponent("history.json")
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
            coordinator.quitting = true
            coordinator.store.closeAllAfterConfirmation()
            coordinator.runtime?.shutdown()
            let output = ProcessInfo.processInfo.environment["KNOTCH_EVIDENCE"] ?? "/tmp/knotch-clipboard-results.json"
            let report: [String: Any] = ["engine": "982fe90d941e4b4aab4905ffcbcfdea60bd83343", "results": records]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            exit(records.contains { $0["result"] == "FAILED" } ? 1 : 0)
        }
        let history = ClipboardHistory(pasteboard: board, storageURL: file)
        board.clearContents()
        board.setString("KNOTCH_CLIPBOARD_TEXT", forType: .string)
        history.captureChange()
        check("Text capture", history.entries.first?.kind == .text && history.entries.first?.text == "KNOTCH_CLIPBOARD_TEXT",
              "A bounded plain-text item was captured from an isolated pasteboard")
        let textID = history.entries.first?.id

        board.clearContents()
        board.setString("https://example.com/fixture", forType: .string)
        history.captureChange()
        check("Link capture", history.entries.first?.kind == .link,
              "An HTTPS URL is labelled as a link without opening it")

        board.clearContents()
        board.setString("Formatted fixture", forType: .string)
        board.setData(Data("{\\rtf1\\ansi Formatted fixture}".utf8), forType: .rtf)
        history.captureChange()
        check("Rich text capture", history.entries.first?.kind == .richText && history.entries.first?.data != nil,
              "RTF and plain fallback remain in one local entry")

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        board.clearContents()
        board.setData(png, forType: .png)
        history.captureChange()
        check("Image capture", history.entries.first?.kind == .image && history.entries.first?.data == png,
              "A small PNG image was captured with its binary representation")
        if let image = history.entries.first {
            let export = ClipboardImageExport(base: folder, processID: 12345)
            let imagePath = try? export.path(for: image)
            let imageMode = imagePath.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? NSNumber)?.intValue }
            let exported = imagePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            check("Image drop exports private file", exported == png && imageMode == 0o600,
                  "A screenshot drop creates an owner-only image file with the original bytes")
            export.cleanUp()
            check("Image drop cleanup", imagePath.map { !FileManager.default.fileExists(atPath: $0) } ?? false,
                  "The app removes its exported image when the session ends")
        }

        let dragBoard = NSPasteboard.withUniqueName()
        dragBoard.setString(UUID().uuidString, forType: ClipboardTerminalDrop.pasteboardType)
        check("Private drag identifier", ClipboardTerminalDrop.entryID(from: dragBoard) != nil,
              "The destination resolves an opaque internal entry ID")
        dragBoard.releaseGlobally()
        check("File path escaping", ClipboardTerminalDrop.escapedPath("/tmp/a b'c.png") == "/tmp/a\\ b\\'c.png"
              && ClipboardTerminalDrop.escapedPath("/tmp/a\nb") == nil,
              "Dropped file paths escape shell metacharacters and reject control characters")
        check("Unsafe text detection", ClipboardTerminalDrop.needsConfirmation("echo one\necho two")
              && !ClipboardTerminalDrop.needsConfirmation("plain text"),
              "Multiline clipboard text requires confirmation before insertion")
        let externalBoard = NSPasteboard.withUniqueName()
        externalBoard.setData(png, forType: .png)
        check("External screenshot recognized", ExternalTerminalDrop.canAccept(externalBoard)
              && ExternalTerminalDrop.content(from: externalBoard).map {
                  if case .image = $0 { return true }; return false
              } == true,
              "A macOS image drag is accepted without Knotch's private entry ID")
        externalBoard.releaseGlobally()

        board.clearContents()
        board.writeObjects([folder.appendingPathComponent("fixture.txt") as NSURL])
        history.captureChange()
        check("File capture", history.entries.first?.kind == .files
              && history.entries.first?.fileURLs?.first?.lastPathComponent == "fixture.txt",
              "File references were captured as URLs without reading file contents")

        let count = history.entries.count
        board.clearContents()
        board.setString("fixture secret", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        history.captureChange()
        check("Concealed item excluded", history.entries.count == count,
              "Pasteboard items marked concealed are not retained")

        history.setPaused(true)
        board.clearContents()
        board.setString("PAUSED_FIXTURE", forType: .string)
        history.captureChange()
        history.setPaused(false)
        check("Pause capture", history.entries.count == count,
              "Content copied while paused is not backfilled")

        if let text = history.entries.first(where: { $0.id == textID }) {
            history.copy(text)
        }
        check("Copy earlier item", board.string(forType: .string) == "KNOTCH_CLIPBOARD_TEXT"
              && history.entries.count == count,
              "Selecting an older item restores it without adding a duplicate")

        if let image = history.entries.first(where: { $0.kind == .image }) { history.copy(image) }
        check("Restore image", board.data(forType: .png) == png,
              "Selecting an image restores its PNG representation")
        if let rich = history.entries.first(where: { $0.kind == .richText }) { history.copy(rich) }
        check("Restore rich text", board.string(forType: .string) == "Formatted fixture"
              && board.data(forType: .rtf) != nil,
              "Selecting formatted text restores both plain and RTF representations")
        if let files = history.entries.first(where: { $0.kind == .files }) { history.copy(files) }
        let restoredFiles = board.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check("Restore files", restoredFiles?.first?.lastPathComponent == "fixture.txt",
              "Selecting a file item restores a file URL without reading its contents")

        let restored = ClipboardHistory(pasteboard: board, storageURL: file)
        check("Local history reload", restored.entries.count == count && restored.entries.first?.kind == .files,
              "History reloads from the user-private local file")
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        let folderMode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        check("Private storage permissions", fileMode == 0o600 && folderMode == 0o700,
              "The local history file and its parent directory are owner-only")
        if let textID { restored.togglePinned(textID) }
        restored.clearUnpinned()
        check("Pin and clear", restored.entries.count == 1 && restored.entries[0].id == textID,
              "Clear unpinned retains the pinned item")
        restored.setPersistsHistory(false)
        check("Disable persistence", !FileManager.default.fileExists(atPath: file.path),
              "Turning persistence off removes the local history file")

        let beforeTimer = restored.entries.count
        restored.start()
        board.clearContents()
        board.setString("TIMER_CAPTURE_FIXTURE", forType: .string)
        try? await Task.sleep(for: .milliseconds(750))
        restored.stop()
        check("Automatic observation", restored.entries.count == beforeTimer + 1
              && restored.entries.first?.text == "TIMER_CAPTURE_FIXTURE",
              "A pasteboard change was captured by the running timer without a direct capture call")

        coordinator.useClipboardForFixture(restored)
        if let runtime = coordinator.runtime,
           let session = try? GhosttySession(runtime: runtime, directory: folder, testCommand: "/bin/zsh -f") {
            coordinator.store.adoptFixture(session)
            coordinator.attach(session)
            let surface = session.surface
            let sharedSize = coordinator.overlay?.layout?.panelFrame.size
            coordinator.showClipboard()
            check("Shared Clipboard panel size", coordinator.overlay?.layout?.panelFrame.size == sharedSize,
                  "Switching from Terminal to Clipboard retains the same panel dimensions")
            check("Clipboard tab keeps shell", coordinator.statusLabel.stringValue == "Clipboard"
                  && session.surface == surface && session.view.superview == nil,
                  "Selecting Clipboard detaches but does not destroy the Ghostty surface")
            coordinator.selectSession(id: session.id)
            check("Return to shell", session.surface == surface && session.view.superview === coordinator.container,
                  "Returning from Clipboard presents the same terminal view")
            coordinator.overlay?.setUserPanelSize(CGSize(width: 900, height: 600))
            let customSize = coordinator.overlay?.layout?.panelFrame.size
            coordinator.showClipboard()
            check("Custom size shared with Clipboard", coordinator.overlay?.layout?.panelFrame.size == customSize,
                  "Saved panel dimensions are retained when the Clipboard tab opens")
            coordinator.showAccessSettings()
            check("Custom size shared with Settings", coordinator.overlay?.layout?.panelFrame.size == customSize,
                  "Settings uses the same custom dimensions as Terminal and Clipboard")
            coordinator.selectSession(id: session.id)
            coordinator.overlay?.setUserPanelSize(nil)
            let marker = folder.appendingPathComponent("drop-must-not-run")
            let command = "touch \(marker.path)"
            board.clearContents()
            board.setString(command, forType: .string)
            restored.captureChange()
            coordinator.showClipboard()
            coordinator.overlay?.settlePresentationForFixture()
            NSApp.activate()
            coordinator.overlay?.panel.makeKeyAndOrderFront(nil)
            try? await HarnessQualification.waitFor({ coordinator.overlay?.panel.isKeyWindow == true },
                                                    timeout: 3, description: "clipboard panel activation")
            coordinator.hoverClipboardTabForFixture(sessionID: session.id)
            check("Drag hover focuses terminal", coordinator.store.selectedID == session.id
                  && coordinator.overlay?.panel.firstResponder === session.view
                  && session.surface == surface,
                  "Selected=\(coordinator.store.selectedID == session.id), key=\(coordinator.overlay?.panel.isKeyWindow == true), responder=\(coordinator.overlay?.panel.firstResponder === session.view), sameSurface=\(session.surface == surface)")
            let accepted = restored.entries.first.map {
                coordinator.acceptClipboardDropForFixture(entryID: $0.id, sessionID: session.id)
            } ?? false
            do {
                try await HarnessQualification.waitFor({
                    HarnessQualification.screen(session).contains(command)
                }, description: "clipboard drop insertion")
                check("Drop inserts without Return", accepted && !FileManager.default.fileExists(atPath: marker.path)
                      && session.surface == surface,
                      "Ghostty received text in the same live surface; the command did not run")
            } catch {
                check("Drop inserts without Return", false, error.localizedDescription)
            }
            coordinator.overlay?.hide(restoreFocus: false)
            coordinator.overlay?.settlePresentationForFixture()
            coordinator.overlay?.externalDragChanged(true)
            coordinator.overlay?.settlePresentationForFixture()
            check("External drag opens notch", coordinator.overlay?.state.presentation == .interactive
                  && coordinator.overlay?.panel.isVisible == true && session.surface == surface,
                  "Dragging an accepted external item over the notch reveals the existing terminal")
            let screenshotBoard = NSPasteboard.withUniqueName()
            screenshotBoard.setData(png, forType: .png)
            let acceptedScreenshot = coordinator.acceptExternalDropForFixture(screenshotBoard)
            try? await HarnessQualification.waitFor({
                HarnessQualification.screen(session).contains("Knotch-Clipboard-Drops-")
            }, description: "external screenshot path")
            check("External screenshot reaches Ghostty", acceptedScreenshot
                  && restored.entries.first?.kind == .image
                  && HarnessQualification.screen(session).contains("Knotch-Clipboard-Drops-")
                  && session.surface == surface,
                  "Accepted=\(acceptedScreenshot), kind=\(String(describing: restored.entries.first?.kind)), screen=\(HarnessQualification.screen(session).suffix(180))")
            screenshotBoard.releaseGlobally()

            let fileURL = folder.appendingPathComponent("Screenshot 1.png")
            let filePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
            try? filePNG.write(to: fileURL)
            let fileBoard = NSPasteboard.withUniqueName()
            fileBoard.writeObjects([fileURL as NSURL])
            let acceptedFile = coordinator.acceptExternalDropForFixture(fileBoard)
            try? await HarnessQualification.waitFor({
                restored.entries.first?.data == filePNG
                    && HarnessQualification.screen(session).contains(restored.entries.first?.id.uuidString ?? "NO_ENTRY")
            }, description: "dragged screenshot file path")
            check("External screenshot file reaches Ghostty", acceptedFile
                  && restored.entries.first?.kind == .image
                  && restored.entries.first?.data == filePNG
                  && HarnessQualification.screen(session).contains(restored.entries.first?.id.uuidString ?? "NO_ENTRY"),
                  "A screenshot file is copied into local history and its private image path is inserted without Return")
            fileBoard.releaseGlobally()

            let ordinaryFile = folder.appendingPathComponent("notes file.txt")
            try? Data("ordinary fixture".utf8).write(to: ordinaryFile)
            let ordinaryBoard = NSPasteboard.withUniqueName()
            ordinaryBoard.writeObjects([ordinaryFile as NSURL])
            let acceptedOrdinary = coordinator.acceptExternalDropForFixture(ordinaryBoard)
            try? await HarnessQualification.waitFor({
                HarnessQualification.screen(session).contains("notes\\ file.txt")
            }, description: "ordinary dragged file path")
            check("Non-image file remains a path", acceptedOrdinary
                  && restored.entries.first?.kind == .files
                  && HarnessQualification.screen(session).contains("notes\\ file.txt"),
                  "Ordinary files keep URL references and insert an escaped path")
            ordinaryBoard.releaseGlobally()

            let promiseBoard = NSPasteboard.withUniqueName()
            let promiseDelegate = ScreenshotPromiseFixture(data: filePNG)
            let provider = NSFilePromiseProvider(fileType: "public.png", delegate: promiseDelegate)
            promiseBoard.writeObjects([provider])
            let promiseSupported = ExternalTerminalDrop.canAccept(promiseBoard)
                && ExternalTerminalDrop.content(from: promiseBoard).map {
                    if case .promises = $0 { return true }; return false
                } == true
            check("Floating screenshot promise recognized", promiseSupported,
                  "A file promise is recognized; fulfillment requires a live AppKit drag session")
            promiseBoard.releaseGlobally()
            coordinator.overlay?.externalDragChanged(false)
            coordinator.overlay?.hide(restoreFocus: false)
            session.view.removeFromSuperview()
            coordinator.store.closeAfterConfirmation(id: session.id)
        } else {
            check("Clipboard tab keeps shell", false, "Fixture Ghostty session failed to start")
        }
    }
}
#endif
