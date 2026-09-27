import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    @Published private(set) var canCheck = false
    @Published private(set) var canRestart = false
    @Published private(set) var status = "This is a local build. Install a release build to receive updates."
    private var updater: SPUUpdater?
    private var driver: KnotchUpdateDriver?
    private var observation: NSKeyValueObservation?
    var beforeUserCheck: (() -> Void)?

    func start() {
        guard updater == nil,
              Bundle.main.object(forInfoDictionaryKey: "KnotchUpdatesEnabled") as? String == "YES",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let driver = KnotchUpdateDriver(hostBundle: .main, delegate: nil)
        driver.onRestartAvailability = { [weak self] ready in
            self?.canRestart = ready
            self?.status = ready ? "Update ready. Restarting ends active terminal sessions." : "Updates are checked automatically."
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        self.driver = driver
        self.updater = updater
        do {
            try updater.start()
            status = "Updates are checked automatically."
            observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.canCheck = self?.updater?.canCheckForUpdates ?? false }
            }
        } catch {
            status = "Updates could not start. Please reopen Knotch."
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let updater, canCheck else { return }
        beforeUserCheck?()
        NSApp.activate()
        updater.checkForUpdates()
    }

    @objc func restartToUpdate(_ sender: Any?) {
        guard canRestart else { return }
        beforeUserCheck?()
        driver?.restart()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(restartToUpdate(_:)) ? canRestart : canCheck
    }
}

/// Keep Sparkle's standard download/error UI, and expose its verified install
/// callback to Settings. Never restart by killing the app or opening another copy.
@MainActor
final class KnotchUpdateDriver: SPUStandardUserDriver {
    var onRestartAvailability: ((Bool) -> Void)?
    private var restartAction: (() -> Void)?

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var replied = false
        let choose: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard !replied else { return }
            replied = true
            self?.setRestartAction(nil)
            reply(choice)
        }
        setRestartAction { choose(.install) }
        super.showReady(toInstallAndRelaunch: choose)
    }

    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                      retryTerminatingApplication: @escaping () -> Void) {
        // Sparkle provides a repeatable retry when the user cancels termination.
        setRestartAction(applicationTerminated ? nil : retryTerminatingApplication)
        super.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                   retryTerminatingApplication: retryTerminatingApplication)
    }

    override func dismissUpdateInstallation() {
        setRestartAction(nil)
        super.dismissUpdateInstallation()
    }

    func restart() {
        restartAction?()
    }

    private func setRestartAction(_ action: (() -> Void)?) {
        restartAction = action
        onRestartAvailability?(action != nil)
    }
}
