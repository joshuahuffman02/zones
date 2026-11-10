import AppKit
import Sparkle

/// Keeps Zones up to date from GitHub Releases with Sparkle. Checks every hour and on wake, downloads in
/// the background, and installs once you've stepped away for 30 seconds (Zones relaunches in about a second).
/// Builds without a feed (none today) skip all of it.
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    /// True while you're editing zones or dragging: no relaunch then.
    var isBusy: () -> Bool = { false }
    private var installNow: (() -> Void)?
    private var readySince: Date?
    private var waitTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard feed.hasPrefix("https://"), Bundle.main.bundleURL.pathExtension == "app" else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.updater.automaticallyChecksForUpdates = true
        c.updater.automaticallyDownloadsUpdates = true
        c.updater.updateCheckInterval = 3600
        c.startUpdater()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkAfterWake() }
    }

    var isAvailable: Bool { controller != nil }
    var updateReady: Bool { installNow != nil }

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    /// Install a downloaded update right now.
    func installReady() {
        guard let install = installNow else { return }
        installNow = nil
        waitTimer?.invalidate()
        install()
    }

    private func checkAfterWake() {
        guard let u = controller?.updater, u.automaticallyChecksForUpdates else { return }
        if (u.lastUpdateCheckDate ?? .distantPast).timeIntervalSinceNow < -3600 { u.checkForUpdatesInBackground() }
    }

    // MARK: Installing at a quiet moment

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        readySince = Date()
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.installIfQuiet() }
        return true
    }

    private func installIfQuiet() {
        guard installNow != nil, !isBusy() else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let waiting = Date().timeIntervalSince(readySince ?? Date())
        guard idle >= 30 || waiting > 2 * 3600 else { return }
        installReady()
    }
}
