import AppKit
import ApplicationServices

/// Remembers where your windows sit for each set of connected monitors (laptop alone, laptop plus the
/// ultrawide, …) and puts them back when that set comes back. Plug the ultrawide in and its windows
/// return to their spots; unplug it and the laptop goes back to how you last had it.
///
/// Only windows that existed in that setup move. New windows, and windows of apps that weren't open, stay put.
final class Arrangements {
    struct Placed: Codable {
        var app: String
        var title: String
        var windowID: UInt32
        /// `ZScreen.key` of the monitor the window was on, and its frame relative to that monitor's top left.
        var screen: String
        var frame: CGRect
    }

    private struct Saved: Codable {
        var enabled = true
        var setups: [String: [Placed]] = [:]
    }

    private struct Live {
        let el: AXUIElement
        let placed: Placed
    }

    private struct Pending {
        let generation: Int
        let setup: String
        let windows: [Placed]
    }

    private var saved = Saved()
    private let queue = DispatchQueue(label: "zones.arrangements", qos: .utility)
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// Bumped on every monitor change, so a snapshot taken across one is thrown away.
    private var generation = 0
    private var lastChange = Date.distantPast
    private var settledSetup = ""
    private var pending: Pending?
    private var busy = false

    static var fileURL: URL {
        Store.fileURL.deletingLastPathComponent().appendingPathComponent("windows.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        }
    }

    var enabled: Bool {
        get { saved.enabled }
        set { saved.enabled = newValue; save() }
    }

    /// The current set of monitors, by name and resolution.
    static var currentSetup: String { ZScreen.all.map(\.key).sorted().joined(separator: " + ") }

    func start() {
        guard timer == nil else { return }
        settledSetup = Self.currentSetup
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Remembering

    /// Every 5 seconds: keep the previous snapshot if nothing changed since, then take a new one.
    /// Holding each snapshot back one round means windows macOS shoves around while a monitor
    /// disappears never overwrite the setup they came from.
    private func tick() {
        if let p = pending, p.generation == generation, p.setup == Self.currentSetup {
            merge(p.windows, into: p.setup)
        }
        pending = nil
        guard !busy, Date().timeIntervalSince(lastChange) > 6 else { return }
        let gen = generation
        let setup = Self.currentSetup
        let screens = ZScreen.all.map { ($0.key, $0.fullAX) }
        let apps = Self.apps()
        queue.async {
            let windows = Self.windows(apps: apps, screens: screens).map(\.placed)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.pending = Pending(generation: gen, setup: setup, windows: windows)
            }
        }
    }

    /// Windows seen now replace what was saved. Saved windows that weren't seen but still exist
    /// (on another desktop, minimised, or in a hidden app) are kept.
    private func merge(_ windows: [Placed], into setup: String) {
        let seen = Set(windows.map(\.windowID))
        let alive = existingWindowIDs()
        let kept = (saved.setups[setup] ?? []).filter { !seen.contains($0.windowID) && alive.contains($0.windowID) }
        let next = windows + kept
        guard !next.isEmpty else { return }
        saved.setups[setup] = next
        save()
    }

    // MARK: Restoring

    private func screensChanged() {
        generation += 1
        lastChange = Date()
        pending = nil
        let gen = generation
        // Monitors come and go in steps (and twice around sleep): wait until they've settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, gen == self.generation else { return }
            let setup = Self.currentSetup
            guard setup != settledSetup else { return }
            settledSetup = setup
            if enabled { restore() }
        }
    }

    /// Put windows back where they were the last time these monitors were connected.
    func restore() {
        let setup = Self.currentSetup
        guard let target = saved.setups[setup], !busy else { return }
        busy = true
        let screens = ZScreen.all.map { ($0.key, $0.fullAX) }
        let apps = Self.apps()
        queue.async {
            let moves = Self.match(Self.windows(apps: apps, screens: screens), to: target, screens: screens)
            for (w, r) in moves { w.setFrame(r) }
            // Some apps settle their own frame a moment later: check once more.
            Thread.sleep(forTimeInterval: 1.0)
            for (w, r) in moves {
                if let f = w.frame, !Snapper.close(f, r) { w.setFrame(r) }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lastChange = Date()
            }
        }
    }

    var hasSavedSetup: Bool { saved.setups[Self.currentSetup] != nil }

    /// Pairs live windows with saved spots: the same window first, then same app and title,
    /// then the app's remaining windows in order.
    private static func match(_ live: [Live], to saved: [Placed], screens: [(String, CGRect)]) -> [(AXUIElement, CGRect)] {
        let origin = Dictionary(screens.map { ($0.0, $0.1.origin) }, uniquingKeysWith: { a, _ in a })
        var free = saved.filter { origin[$0.screen] != nil }
        var left = live
        var out: [(AXUIElement, CGRect)] = []
        func pass(_ same: (Live, Placed) -> Bool) {
            left = left.filter { w in
                guard let i = free.firstIndex(where: { same(w, $0) }) else { return true }
                let p = free.remove(at: i)
                let o = origin[p.screen]!
                let r = p.frame.offsetBy(dx: o.x, dy: o.y)
                if !Snapper.close(w.placed.frame, r) { out.append((w.el, r)) }
                return false
            }
        }
        pass { $0.placed.windowID == $1.windowID && $0.placed.app == $1.app }
        pass { !$1.title.isEmpty && $0.placed.app == $1.app && $0.placed.title == $1.title }
        pass { $0.placed.app == $1.app }
        return out
    }

    // MARK: Windows

    private static func apps() -> [(pid_t, String)] {
        NSWorkspace.shared.runningApplications.compactMap { a in
            guard a.activationPolicy == .regular, !a.isHidden, a.processIdentifier != getpid() else { return nil }
            return (a.processIdentifier, a.bundleIdentifier ?? a.localizedName ?? "\(a.processIdentifier)")
        }
    }

    /// Movable windows of these apps, with the monitor each sits on (frame relative to it).
    private static func windows(apps: [(pid_t, String)], screens: [(String, CGRect)]) -> [Live] {
        var out: [Live] = []
        for (pid, app) in apps {
            let a = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(a, 0.25)
            for w in a.elements(kAXWindowsAttribute) {
                AXUIElementSetMessagingTimeout(w, 0.25)
                guard w.bool(kAXMinimizedAttribute) != true, Snapper.isSnappable(w),
                      let f = w.frame, let id = w.windowID,
                      let s = screens.first(where: { $0.1.contains(CGPoint(x: f.midX, y: f.midY)) })
                else { continue }
                let rel = f.offsetBy(dx: -s.1.minX, dy: -s.1.minY)
                out.append(Live(el: w, placed: Placed(app: app, title: w.string(kAXTitleAttribute) ?? "",
                                                      windowID: id, screen: s.0, frame: rel)))
            }
        }
        return out
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.fileURL) }
    }
}
