import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import SwiftUI
import ZonesCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = Store()
    private lazy var snapper = Snapper(store: store)
    private lazy var gapHandles = GapHandles(store: store)
    private let hotkeys = HotKeyCenter()
    private var failedKeys: [String] = []
    private var permissionTimer: Timer?
    private var editor: ZoneEditor?
    private let updater = Updater()
    private let arrangements = Arrangements()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Zones")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            begin()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.begin()
            }
        }
    }

    private func begin() {
        updater.isBusy = { [weak self] in self?.editor != nil || self?.snapper.isDragging == true }
        snapper.start()
        gapHandles.start()
        arrangements.start()
        bindKeys()
    }

    // MARK: Shortcuts

    static let shortcuts: [(String, String)] = [
        ("⇧ while dragging a window", "Show zones, drop to snap"),
        ("⇧⌘ while dragging", "Span from one zone to another"),
        ("Drag the gap between windows", "Resize both sides together"),
        ("⌃⌥ 1 – 9", "Put window in zone 1 – 9"),
        ("⌃⌥ ← →", "Next zone left / right (crosses monitors)"),
        ("⌃⌥ ↑ ↓", "Zone above / below"),
        ("⌃⌥ ↩", "Fill the monitor"),
        ("⌃⌥ E", "Edit zones on the monitor under the mouse"),
    ]

    private func bindKeys() {
        hotkeys.unregisterAll()
        failedKeys = []
        let mods = UInt32(controlKey | optionKey)
        func bind(_ name: String, _ key: Int, _ action: @escaping () -> Void) {
            if !hotkeys.register(keyCode: UInt32(key), modifiers: mods, action: action) { failedKeys.append(name) }
        }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in digits.enumerated() {
            bind("⌃⌥\(i + 1)", k) { [weak self] in self?.snapper.sendFocused(toZone: i) }
        }
        bind("⌃⌥←", kVK_LeftArrow) { [weak self] in self?.snapper.moveFocused(.left) }
        bind("⌃⌥→", kVK_RightArrow) { [weak self] in self?.snapper.moveFocused(.right) }
        bind("⌃⌥↑", kVK_UpArrow) { [weak self] in self?.snapper.moveFocused(.up) }
        bind("⌃⌥↓", kVK_DownArrow) { [weak self] in self?.snapper.moveFocused(.down) }
        bind("⌃⌥↩", kVK_Return) { [weak self] in self?.snapper.fillFocused() }
        bind("⌃⌥E", kVK_ANSI_E) { [weak self] in
            if let s = ZScreen.containing(mouseAX()) { self?.edit(s) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard AXIsProcessTrusted() else {
            menu.addItem(disabled("Waiting for Accessibility permission"))
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Zones", #selector(quit), key: "q"))
            return
        }

        menu.addItem(disabled("Hold ⇧ while dragging a window to snap it"))
        menu.addItem(disabled("Add ⌘ to span several zones"))
        let gr = item("Drag Gaps to Resize Neighbours", #selector(toggleGapResize))
        gr.state = store.gapResize ? .on : .off
        menu.addItem(gr)
        let ar = item("Put Windows Back When Monitors Change", #selector(toggleArrangements))
        ar.state = arrangements.enabled ? .on : .off
        menu.addItem(ar)
        let now = item("Put Windows Back Now", #selector(restoreArrangement))
        now.isEnabled = arrangements.hasSavedSetup
        now.indentationLevel = 1
        menu.addItem(now)
        menu.addItem(.separator())

        for (i, s) in ZScreen.ordered.enumerated() {
            let layout = store.layout(for: s)
            menu.addItem(disabled("\(s.name): \(layout.zoneCount) zone\(layout.zoneCount == 1 ? "" : "s")"))
            let edit = item("Edit Zones…", #selector(editZones(_:)))
            edit.tag = i
            edit.indentationLevel = 1
            menu.addItem(edit)

            let templates = NSMenu()
            for (ti, t) in ZoneLayout.templates.enumerated() {
                let ti_item = item(t.name, #selector(pickTemplate(_:)))
                ti_item.tag = i * 100 + ti
                ti_item.state = t.layout == layout ? .on : .off
                templates.addItem(ti_item)
            }
            let tm = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
            tm.submenu = templates
            tm.indentationLevel = 1
            menu.addItem(tm)
            let show = item("Show Zones", #selector(showZones(_:)))
            show.tag = i
            show.indentationLevel = 1
            menu.addItem(show)
        }
        menu.addItem(.separator())

        let gaps = NSMenu()
        for g in [0, 4, 8, 12, 16, 24] {
            let gi = item("\(g) pt", #selector(pickGap(_:)))
            gi.tag = g
            gi.state = Int(store.gap) == g ? .on : .off
            gaps.addItem(gi)
        }
        let gm = NSMenuItem(title: "Gap Between Windows", action: nil, keyEquivalent: "")
        gm.submenu = gaps
        menu.addItem(gm)

        let keys = NSMenu()
        for (k, what) in Self.shortcuts { keys.addItem(disabled("\(k)\t\(what)")) }
        let km = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        km.submenu = keys
        menu.addItem(km)

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if updater.isAvailable {
            if updater.updateReady {
                menu.addItem(item("Restart to Update", #selector(installUpdate)))
            } else {
                menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
            }
        }
        if !failedKeys.isEmpty {
            menu.addItem(disabled("⚠︎ Taken by another app: " + failedKeys.joined(separator: " ")))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Zones \(updater.version)"))
        menu.addItem(item("Quit Zones", #selector(quit), key: "q"))
    }

    @objc private func checkForUpdates() { updater.checkNow() }
    @objc private func installUpdate() { updater.installReady() }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func screen(_ i: Int) -> ZScreen? {
        let all = ZScreen.ordered
        return all.indices.contains(i) ? all[i] : nil
    }

    @objc private func editZones(_ sender: NSMenuItem) {
        if let s = screen(sender.tag) { edit(s) }
    }

    private func edit(_ s: ZScreen) {
        guard editor == nil else { return }
        snapper.overlay.hide()
        gapHandles.paused = true
        editor = ZoneEditor(screen: s, layout: store.layout(for: s), gap: store.gap) { [weak self] layout, gap in
            guard let self else { return }
            if let layout {
                store.setLayout(layout, for: s)
                store.gap = gap
            }
            editor = nil
            gapHandles.paused = false
        }
    }

    @objc private func pickTemplate(_ sender: NSMenuItem) {
        guard let s = screen(sender.tag / 100) else { return }
        store.setLayout(ZoneLayout.templates[sender.tag % 100].layout, for: s)
        snapper.overlay.flash(on: s, rects: store.rects(for: s))
    }

    @objc private func showZones(_ sender: NSMenuItem) {
        guard let s = screen(sender.tag) else { return }
        snapper.overlay.flash(on: s, rects: store.rects(for: s))
    }

    @objc private func toggleGapResize() {
        store.gapResize.toggle()
        gapHandles.refresh()
    }

    @objc private func toggleArrangements() { arrangements.enabled.toggle() }
    @objc private func restoreArrangement() { arrangements.restore() }

    @objc private func pickGap(_ sender: NSMenuItem) {
        store.gap = Double(sender.tag)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Open at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

/// Draws the editor and the drag overlay to PNGs, for checking the look without a live screen.
func renderPreviews(to dir: URL) {
    let size = CGSize(width: 2560, height: 720)
    func save(_ v: NSView, _ name: String) {
        v.frame = CGRect(origin: .zero, size: size)
        let host = NSView(frame: v.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.55, alpha: 1).cgColor
        host.addSubview(v)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
    let layout = ZoneLayout.focusStacked
    let model = EditorModel(layout: layout, gap: 8, screenName: "Odyssey G95C")
    let canvas = EditorCanvas(frame: CGRect(origin: .zero, size: size), model: model)
    save(canvas, "editor.png")
    let bar = NSHostingView(rootView: EditorToolbar(model: model, cancel: {}, save: {}))
    bar.frame = CGRect(origin: .zero, size: bar.fittingSize)
    let barHost = NSView(frame: CGRect(origin: .zero, size: CGSize(width: bar.fittingSize.width + 40, height: bar.fittingSize.height + 40)))
    bar.frame.origin = CGPoint(x: 20, y: 20)
    barHost.addSubview(bar)
    if let rep = barHost.bitmapImageRepForCachingDisplay(in: barHost.bounds) {
        barHost.cacheDisplay(in: barHost.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("toolbar.png"))
    }
    let drag = DragOverlayView(frame: CGRect(origin: .zero, size: size))
    drag.rects = ZoneLayout.columns(4).rects(in: CGRect(origin: .zero, size: size), gap: 8)
    drag.highlight = ZoneLayout.columns(4).span(1, 2, in: CGRect(origin: .zero, size: size), gap: 8)
    save(drag, "drag.png")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
