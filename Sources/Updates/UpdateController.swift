import AppKit
import Sparkle

/// Only distribution builds join the public update channel. Development and
/// qualification builds must never replace themselves with a public release.
@MainActor
final class UpdateController: NSObject, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    var beforeUserCheck: (() -> Void)?

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "KnotchUpdatesEnabled") as? String == "YES",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller else { return }
        beforeUserCheck?()
        NSApp.activate()
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}
