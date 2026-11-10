import AppKit
import ApplicationServices
import Carbon
import EdgeStashCore

enum StashError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frame(of element: AXUIElement) throws -> CGRect {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
        throw StashError.message("This window does not expose its position and size.")
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else {
        throw StashError.message("This window has an invalid frame.")
    }
    return CGRect(origin: point, size: dimensions)
}

func move(_ element: AXUIElement, to rect: CGRect, resize: Bool = false) throws {
    var point = rect.origin
    guard let position = AXValueCreate(.cgPoint, &point),
          AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success else {
        throw StashError.message("The application refused to move its window.")
    }
    if resize, let actual = try? frame(of: element),
       abs(actual.width - rect.width) > 1 || abs(actual.height - rect.height) > 1 {
        var size = rect.size
        guard let value = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success else {
            throw StashError.message("The application refused to restore its window size.")
        }
        guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success else {
            throw StashError.message("The application refused to restore its window position after resizing.")
        }
    }
    if resize, !framesMatch(try frame(of: element), rect) {
        throw StashError.message("The application constrained the restored window. Its recovery entry has been kept; try Restore again.")
    }
}

func minimize(_ element: AXUIElement, _ flag: Bool) throws {
    if (attribute(element, kAXMinimizedAttribute) as? Bool) == flag { return }
    guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse) == .success else {
        throw StashError.message("The application refused to change its window's minimized state.")
    }
}

struct Recovery: Codable {
    let pid: Int32
    let launched: Date
    let title: String
    let original: CGRect
}

final class IndicatorButton: NSButton {
    var icon: NSImage?
    var count = 1
    var vertical = true
    var tint = NSColor.systemTeal

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        let size = min(22, (vertical ? bounds.width : bounds.height) - 6)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let offset: CGFloat = count > 1 ? 8 : 0
        let rect = CGRect(x: center.x - size / 2 - (vertical ? 0 : offset),
                          y: center.y - size / 2 + (vertical ? offset : 0), width: size, height: size)
        icon?.draw(in: rect)
        if count > 1 {
            let text = String(count) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: vertical ? center.x - size.width / 2 : rect.maxX + 5,
                                 y: vertical ? rect.minY - size.height - 2 : center.y - size.height / 2), withAttributes: attributes)
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).stroke()
        }
    }
}

final class StashedWindow {
    let element: AXUIElement
    let recovery: Recovery
    let edge: Edge
    let screen: CGRect
    let tab: NSPanel
    let appID: String
    let appName: String
    var animation: Timer?
    var revealed = false
    var minimized = false
    var hoverSince: Date?
    var leftSince: Date?

    init(element: AXUIElement, recovery: Recovery, edge: Edge, screen: CGRect, tab: NSPanel) {
        self.element = element; self.recovery = recovery; self.edge = edge; self.screen = screen; self.tab = tab
        let app = NSRunningApplication(processIdentifier: recovery.pid)
        appID = app?.bundleIdentifier ?? String(recovery.pid)
        appName = app?.localizedName ?? "Application"
    }
}

final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var entries: [StashedWindow] = []
    var recovery: [Recovery] = []
    var timer: Timer?
    var hotKeys: [EventHotKeyRef] = []
    var hotKeyHandler: EventHandlerRef?
    var lastFrontmost: NSRunningApplication?
    var lastError: String?
    var journalReadable = true
    var menuTarget: AXUIElement?
    var preferences = Preferences()
    var settingsController: SettingsWindowController?
    var escapeTap: CFMachPort?
    var escapeSource: CFRunLoopSource?
    var lastRevealed: StashedWindow?
    let preferencesKey = "EdgeStash.preferences.v1"
    var activeEntries: [StashedWindow] { entries.filter { $0.tab.isOnActiveSpace } }
    let journalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeStash/recovery.json")
    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    var screens: [CGRect] { NSScreen.screens.map { flip($0.frame, primaryHeight: primaryHeight) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.trailinghalf.inset.filled", accessibilityDescription: "EdgeStash")
        statusItem.button?.toolTip = "EdgeStash — stash windows at the screen edge"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        let applicationMenu = NSMenu()
        let menuBar = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        menuBar.addItem(applicationItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self; applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit EdgeStash", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; applicationMenu.addItem(quitItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu; menuBar.addItem(windowItem)
        NSApp.mainMenu = menuBar
        lastFrontmost = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsFocusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsFocusChanged), name: NSApplication.didResignActiveNotification, object: nil)
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                recovery = try JSONDecoder().decode([Recovery].self, from: Data(contentsOf: journalURL))
            }
        } catch { journalReadable = false; lastError = "Recovery file could not be read: \(error.localizedDescription)" }
        if let data = UserDefaults.standard.data(forKey: preferencesKey) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: data) }
            catch { report("Saved settings could not be read. Defaults are in use; the saved value was preserved.") }
        }
        registerShortcuts()
        configureEscape()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        if AXIsProcessTrusted() { recoverWindows() }
        if CommandLine.arguments.contains("--settings") || UserDefaults.standard.data(forKey: preferencesKey) == nil { showSettings() }
    }

    @objc func frontmostChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastFrontmost = app }
        if preferences.dismissMode == .escape, escapeTap == nil, AXIsProcessTrusted() { configureEscape() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTarget = try? focusedWindow()
        rebuildMenu(menu)
    }

    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        let heading = NSMenuItem(title: "EdgeStash · \(activeEntries.count) on this desktop", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        if !trusted { add("Enable Accessibility…", action: #selector(enableAccessibility), to: menu) }
        for (index, edge) in Edge.allCases.enumerated() {
            let item = add("Stash \(edge.title)", action: #selector(stashMenu(_:)), to: menu)
            item.tag = index; item.isEnabled = trusted
        }
        menu.addItem(.separator())
        add("Unstash Focused Window", action: #selector(unstashFocused), to: menu).isEnabled = trusted && !entries.isEmpty
        add("Restore All Windows", action: #selector(restoreAllMenu), to: menu).isEnabled = !entries.isEmpty
        for (index, entry) in entries.enumerated() where entry.tab.isOnActiveSpace {
            let item = add("Restore \(entry.recovery.title.isEmpty ? "Untitled window" : entry.recovery.title)", action: #selector(restoreEntry(_:)), to: menu)
            item.tag = index
        }
        if !recovery.isEmpty { add("Recover \(recovery.count) Windows from Previous Run", action: #selector(recoverWindows), to: menu).isEnabled = trusted }
        menu.addItem(.separator())
        let settingsItem = add("Settings…", action: #selector(showSettings), to: menu)
        settingsItem.keyEquivalent = ","
        add("Keyboard Shortcuts & Help…", action: #selector(showHelp), to: menu)
        if let error = lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: ""); item.toolTip = error; menu.addItem(item)
        }
        add("Quit EdgeStash (Restores Windows)", action: #selector(quit), to: menu)
    }

    @discardableResult func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }

    @objc func enableAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Keep a window at the edge"
        alert.informativeText = "Focus a window, then use Control–Option–Command plus an arrow key to stash it. Hover an app indicator to reveal; click to show or cycle its stack. Right-click an indicator for individual reveal and unstash commands.\n\nSettings lets you change every shortcut, indicator size and color, motion, and dismissal. Escape mode hides only the focused revealed stash; moving the cursor or focus away leaves it open. Stashes stay on their original desktop.\n\nUnstash restores the pre-stash frame. Some apps require native minimization when macOS blocks offscreen movement. Enable Accessibility to control other apps."

        alert.runModal()
    }

    func focusedWindow() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw StashError.message("Enable Accessibility access for EdgeStash first.") }
        let app = NSWorkspace.shared.frontmostApplication
        guard let target = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastFrontmost : app else {
            throw StashError.message("Focus a normal application window first.")
        }
        let element = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        guard let window = elementAttribute(element, kAXFocusedWindowAttribute) else {
            throw StashError.message("The focused application has no accessible window.")
        }
        AXUIElementSetMessagingTimeout(window, 0.4)
        return window
    }

    @objc func stashMenu(_ sender: NSMenuItem) { perform { try stash(Edge.allCases[sender.tag], target: menuTarget) } }
    func stash(_ edge: Edge, target: AXUIElement? = nil) throws {
        guard preferences.enabled else { throw StashError.message("Stashing is paused. Enable it in Settings → Stash.") }
        let window = try target ?? focusedWindow()
        if let entry = entries.first(where: { CFEqual($0.element, window) }) { try restore(entry); return }
        guard attribute(window, "AXFullScreen") as? Bool != true,
              attribute(window, kAXMinimizedAttribute) as? Bool != true else {
            throw StashError.message("Exit full screen or unminimize this window before stashing it.")
        }
        let original = try frame(of: window)
        guard let screen = screens.max(by: { $0.intersection(original).size.area < $1.intersection(original).size.area }),
              !screen.intersection(original).isNull else { throw StashError.message("This window is not on a connected display.") }
        guard !edge.isBlocked(window: original, screen: screen, others: screens.filter { $0 != screen }) else {
            throw StashError.message("Choose an outside display edge; this edge joins another display.")
        }
        var pid: pid_t = 0; AXUIElementGetPid(window, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid), let launched = app.launchDate else {
            throw StashError.message("The window's application is no longer running.")
        }
        let record = Recovery(pid: pid, launched: launched, title: attribute(window, kAXTitleAttribute) as? String ?? "", original: original)
        let tab = TabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tab.isOpaque = false; tab.backgroundColor = .clear; tab.hasShadow = false
        tab.hidesOnDeactivate = false
        tab.level = .floating; tab.collectionBehavior = [.stationary, .ignoresCycle]
        let button = IndicatorButton(title: "", target: self, action: #selector(tabClicked(_:)))
        button.isBordered = false
        button.icon = app.icon
        button.toolTip = "\(app.localizedName ?? "Application") — hover to reveal, click to cycle; right-click for windows"
        button.setAccessibilityLabel("Reveal \(app.localizedName ?? "stashed window")")
        tab.contentView = button
        let entry = StashedWindow(element: window, recovery: record, edge: edge, screen: screen, tab: tab)
        entries.append(entry)
        do {
            try saveJournal()
            tab.orderFrontRegardless()
            try hide(entry)
            layoutTabs()
            refreshSettings()
        }
        catch {
            // Keep the journal and a restore action if a partial AX move cannot be undone.
            if (try? restore(entry)) == nil { layoutTabs() }
            throw error
        }
    }

    func visibleScreen(for entry: StashedWindow) -> CGRect {
        NSScreen.screens.first(where: { flip($0.frame, primaryHeight: primaryHeight) == entry.screen })
            .map { flip($0.visibleFrame, primaryHeight: primaryHeight) } ?? entry.screen
    }

    func presentationFrame(for entry: StashedWindow) -> CGRect {
        entry.edge.revealedFrame(entry.recovery.original, screen: visibleScreen(for: entry), inset: preferences.indicatorWidth + 6)
    }

    func slide(_ entry: StashedWindow, to destination: CGRect, completion: @escaping (Error?) -> Void) {
        entry.animation?.invalidate(); entry.animation = nil
        guard preferences.animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let origin = try? frame(of: entry.element), !framesMatch(origin, destination) else {
            do { try move(entry.element, to: destination, resize: true); completion(nil) }
            catch { completion(error) }
            return
        }
        let start = Date()
        let duration = preferences.animationDuration
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak entry] timer in
            guard let entry else { timer.invalidate(); return }
            let progress = min(1, Date().timeIntervalSince(start) / duration)
            do {
                try move(entry.element, to: slideFrame(from: origin, to: destination, progress: progress), resize: progress >= 1)
                if progress >= 1 {
                    timer.invalidate(); entry.animation = nil; completion(nil)
                }
            } catch {
                timer.invalidate(); entry.animation = nil; completion(error)
            }
        }
        entry.animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide(_ entry: StashedWindow) throws {
        entry.revealed = false; entry.leftSince = nil; entry.hoverSince = nil
        let destination = entry.edge.hiddenFrame(presentationFrame(for: entry), screen: entry.screen)
        slide(entry, to: destination) { [weak self, weak entry] error in
            guard let self, let entry else { return }
            let visible = (try? frame(of: entry.element))?.intersection(entry.screen)
            if error == nil, let visible, visible.isNull || visible.width <= 12 || visible.height <= 12 {
                entry.minimized = false
                return
            }
            do {
                // shortcut: macOS clamps some edges; use native minimization when a full offscreen slide is unavailable.
                try minimize(entry.element, true)
                entry.minimized = true
            } catch {
                entry.revealed = true
                self.report("Could not hide \(entry.appName): \(error.localizedDescription). Use its restore action.")
            }
        }
    }

    func reveal(_ entry: StashedWindow, activate: Bool = false) throws {
        guard entry.tab.isOnActiveSpace else { return }
        if preferences.stackByApp {
            for other in activeEntries where other !== entry && other.edge == entry.edge && other.screen == entry.screen && other.revealed {
                try hide(other)
            }
        }
        try minimize(entry.element, false)
        entry.minimized = false
        entry.revealed = true; entry.leftSince = nil; entry.hoverSince = nil
        lastRevealed = entry
        slide(entry, to: presentationFrame(for: entry)) { [weak self, weak entry] error in
            guard let self, let entry else { return }
            if let error {
                entry.revealed = false
                entry.hoverSince = Date().addingTimeInterval(1)
                self.report(error.localizedDescription)
            }
            else { _ = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString) }
        }
        _ = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
        if activate { NSRunningApplication(processIdentifier: entry.recovery.pid)?.activate(options: [.activateIgnoringOtherApps]) }
    }

    func restore(_ entry: StashedWindow) throws {
        entry.animation?.invalidate(); entry.animation = nil
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(entry.element, kAXRoleAttribute as CFString, &role)
        if status != .invalidUIElement,
           NSRunningApplication(processIdentifier: entry.recovery.pid)?.launchDate == entry.recovery.launched {
            try minimize(entry.element, false)
            let destination = restoreFrame(entry.recovery.original)
            try move(entry.element, to: destination, resize: true)
        }
        entry.tab.close(); entries.removeAll { $0 === entry }
        try saveJournal(); layoutTabs(); refreshSettings()
    }

    func restoreFrame(_ original: CGRect) -> CGRect {
        let visible = NSScreen.screens.map { flip($0.visibleFrame, primaryHeight: primaryHeight) }
        guard let best = visible.max(by: { $0.intersection(original).size.area < $1.intersection(original).size.area }) else { return original }
        return fitting(original, inside: best)
    }

    func stack(for entry: StashedWindow) -> [StashedWindow] {
        activeEntries.filter { $0.edge == entry.edge && $0.screen == entry.screen && (!preferences.stackByApp ? $0 === entry : $0.appID == entry.appID) }
    }

    @objc func tabClicked(_ sender: NSButton) {
        guard let leader = entries.first(where: { $0.tab.contentView === sender }) else { return }
        let members = stack(for: leader)
        guard !members.isEmpty else { return }
        if members.count == 1, leader.revealed { perform { try hide(leader) }; return }
        let current = members.firstIndex(where: { $0.revealed })
        let next = members[((current ?? -1) + 1) % members.count]
        perform { try reveal(next, activate: true) }
    }

    @objc func revealMenuEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? StashedWindow, entries.contains(where: { $0 === entry }) else { return }
        perform { try reveal(entry, activate: true) }
    }

    @objc func restoreMenuEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? StashedWindow, entries.contains(where: { $0 === entry }) else { return }
        perform { try restore(entry) }
    }

    func cycleStack() {
        guard let current = lastRevealed, current.tab.isOnActiveSpace else { return }
        let members = stack(for: current)
        guard let index = members.firstIndex(where: { $0 === current }), !members.isEmpty else { return }
        perform { try reveal(members[(index + 1) % members.count], activate: true) }
    }

    @objc func restoreEntry(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        let entry = entries[sender.tag]; perform { try restore(entry) }
    }
    @objc func unstashFocused() {
        perform {
            let window = try menuTarget ?? focusedWindow()
            guard let entry = entries.first(where: { CFEqual($0.element, window) }) else { return }
            try restore(entry)
        }
        menuTarget = nil
    }
    @objc func restoreAllMenu() { restoreAll() }
    func restoreAll() {
        var failures: [String] = []
        for entry in entries { do { try restore(entry) } catch { failures.append(error.localizedDescription) } }
        if let failure = failures.first { report(failure) }
    }
    @objc func displaysChanged() { restoreAll() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        restoreAll()
        return entries.isEmpty ? .terminateNow : .terminateCancel
    }

    func layoutTabs() {
        let active = activeEntries
        var leaders: [StashedWindow] = []
        for entry in active {
            if preferences.stackByApp, leaders.contains(where: { $0.appID == entry.appID && $0.edge == entry.edge && $0.screen == entry.screen }) {
                // Keep the window ordered so AppKit retains its originating Space membership.
                entry.tab.alphaValue = 0
                entry.tab.ignoresMouseEvents = true
            } else { leaders.append(entry) }
        }
        for entry in leaders {
            entry.tab.alphaValue = 1
            entry.tab.ignoresMouseEvents = false
            let peers = leaders.filter { $0.edge == entry.edge && $0.screen == entry.screen }
            let index = peers.firstIndex(where: { $0 === entry }) ?? 0
            let anchor = peers.map { ($0.edge == .left || $0.edge == .right) ? $0.recovery.original.midY : $0.recovery.original.midX }.min()
            entry.tab.setFrame(flip(entry.edge.tabFrame(screen: visibleScreen(for: entry), index: index, count: peers.count,
                width: preferences.indicatorWidth, length: preferences.indicatorLength, anchor: anchor), primaryHeight: primaryHeight), display: true)
            if let button = entry.tab.contentView as? IndicatorButton {
                let members = stack(for: entry)
                button.count = members.count
                button.vertical = entry.edge == .left || entry.edge == .right
                button.tint = colorFromHex(preferences.appColors[entry.appID] ?? preferences.indicatorColor)
                button.needsDisplay = true
                let menu = NSMenu()
                for member in members {
                    let item = NSMenuItem(title: "Reveal \(member.recovery.title.isEmpty ? member.appName : member.recovery.title)", action: #selector(revealMenuEntry(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = member; menu.addItem(item)
                    let restore = NSMenuItem(title: "Unstash \(member.recovery.title.isEmpty ? member.appName : member.recovery.title)", action: #selector(restoreMenuEntry(_:)), keyEquivalent: "")
                    restore.target = self; restore.representedObject = member; menu.addItem(restore)
                }
                button.menu = menu
                button.setAccessibilityLabel("\(entry.appName), \(members.count) stashed window\(members.count == 1 ? "" : "s"). Click to reveal or cycle.")
            }
            entry.tab.orderFrontRegardless()
        }
    }

    @objc func spaceChanged() {
        for entry in entries where entry.revealed { perform { try hide(entry) } }
        layoutTabs()
        refreshSettings()
    }

    @objc func tick() {
        guard AXIsProcessTrusted(), !entries.isEmpty else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        for entry in entries {
            guard NSRunningApplication(processIdentifier: entry.recovery.pid)?.launchDate == entry.recovery.launched else {
                perform { try restore(entry) }; continue
            }
            guard entry.tab.isOnActiveSpace, entry.animation == nil else { continue }
            let leader = stack(for: entry).first
            let tabFrame = leader?.tab.frame ?? entry.tab.frame
            if tabFrame.insetBy(dx: -2, dy: -2).contains(point) {
                entry.leftSince = nil
                guard leader === entry else { continue }
                let selected = stack(for: entry).first(where: { $0.revealed }) ?? entry
                if !selected.revealed {
                    if entry.hoverSince == nil { entry.hoverSince = now }
                    if now.timeIntervalSince(entry.hoverSince!) >= preferences.showDelay { perform { try reveal(selected) } }
                }
            } else if entry.revealed, preferences.dismissMode == .pointerLeaves {
                let visible = (try? frame(of: entry.element)).map { flip($0, primaryHeight: primaryHeight).insetBy(dx: -12, dy: -12) }
                if visible?.contains(point) == true { entry.leftSince = nil }
                else {
                    if entry.leftSince == nil { entry.leftSince = now }
                    if now.timeIntervalSince(entry.leftSince!) >= preferences.hideDelay {
                        perform { try hide(entry) }
                    }
                }
            } else { entry.hoverSince = nil }
        }
    }

    @objc func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(preferences: preferences,
                onChange: { [weak self] in self?.applyPreferences($0) },
                onEnableAccessibility: { [weak self] in self?.enableAccessibility() },
                onRestoreAll: { [weak self] in self?.restoreAll() })
            NotificationCenter.default.addObserver(self, selector: #selector(settingsFocusChanged), name: NSWindow.didBecomeKeyNotification, object: settingsController?.window)
            NotificationCenter.default.addObserver(self, selector: #selector(settingsFocusChanged), name: NSWindow.didResignKeyNotification, object: settingsController?.window)
        }
        refreshSettings()
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSettings() {
        var apps: [(id: String, name: String)] = []
        for entry in activeEntries where !apps.contains(where: { $0.id == entry.appID }) { apps.append((entry.appID, entry.appName)) }
        settingsController?.update(preferences: preferences, apps: apps)
    }

    func applyPreferences(_ value: Preferences) {
        var value = value; value.normalize()
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: preferencesKey)
            let old = preferences
            preferences = value
            if old.shortcuts != value.shortcuts { registerShortcuts() }
            if old.dismissMode != value.dismissMode { configureEscape() }
            if old.enabled && !value.enabled { restoreAll() }
            for entry in activeEntries where entry.revealed { perform { try reveal(entry) } }
            layoutTabs()
        } catch { report("Settings could not be saved: \(error.localizedDescription)") }
    }

    func configureEscape() {
        if let escapeTap { CFMachPortInvalidate(escapeTap) }
        if let escapeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeSource, .commonModes) }
        escapeTap = nil; escapeSource = nil
        guard preferences.dismissMode == .escape else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        escapeTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = app.escapeTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if event.getIntegerValueField(.keyboardEventKeycode) == 53,
                          event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
                          app.handleEscape() { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: context)
        guard let escapeTap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, escapeTap, 0) else {
            report("Escape-to-hide needs Accessibility access. Enable it and reselect Escape in Settings; tabs remain clickable to hide.")
            return
        }
        escapeSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func handleEscape() -> Bool {
        guard preferences.dismissMode == .escape, settingsController?.window?.isKeyWindow != true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focused = try? focusedWindow(),
              let entry = activeEntries.first(where: { $0.revealed && CFEqual($0.element, focused) }) else { return false }
        perform { try hide(entry) }
        return true
    }

    func saveJournal() throws {
        guard journalReadable else { throw StashError.message("Repair or move the unreadable recovery.json file before stashing more windows; it has been preserved.") }
        let folder = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(recovery + entries.map(\.recovery)).write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    @objc func recoverWindows() {
        guard AXIsProcessTrusted() else { return }
        var remaining: [Recovery] = []
        for record in recovery {
            guard let app = NSRunningApplication(processIdentifier: record.pid), app.launchDate == record.launched else { continue }
            let element = AXUIElementCreateApplication(record.pid); AXUIElementSetMessagingTimeout(element, 0.4)
            let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let matches = windows.filter { (attribute($0, kAXTitleAttribute) as? String ?? "") == record.title }
            // shortcut: recovery matches a unique title in the same process; changed/duplicate titles need manual recovery.
            guard matches.count == 1 else { remaining.append(record); continue }
            do { try minimize(matches[0], false); try move(matches[0], to: restoreFrame(record.original), resize: true) }
            catch { remaining.append(record) }
        }
        recovery = remaining
        do { try saveJournal() } catch { report(error.localizedDescription) }
        if !remaining.isEmpty { report("Some recovery windows could not be matched. Unminimize them from the Dock or use their app's Window menu; original positions remain in the recovery file.") }
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { report(error.localizedDescription) }
    }
    func report(_ text: String) { lastError = text; NSSound.beep() }

    func registerShortcuts() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
        guard !(NSApp.isActive && settingsController?.window?.isVisible == true) else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, Int(key.id) < ShortcutAction.allCases.count else { return result }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return noErr }
            delegate.menuTarget = nil
            switch ShortcutAction.allCases[Int(key.id)] {
            case .stashLeft: delegate.perform { try delegate.stash(.left) }
            case .stashRight: delegate.perform { try delegate.stash(.right) }
            case .stashTop: delegate.perform { try delegate.stash(.top) }
            case .stashBottom: delegate.perform { try delegate.stash(.bottom) }
            case .unstash: delegate.unstashFocused()
            case .restoreAll: delegate.restoreAll()
            case .cycleStack: delegate.cycleStack()
            }
            return noErr
        }, 1, &eventType, context, &hotKeyHandler)
        guard result == noErr else { report("Global shortcuts could not be installed; use the menu."); return }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = preferences.shortcuts[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x45535448, id: UInt32(index))
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { hotKeys.append(ref) }
            else { report("\(action.title)'s shortcut is in use by another app. Change it in Settings → Shortcuts.") }
        }
    }

    @objc func settingsFocusChanged() { registerShortcuts() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

}

extension CGSize { var area: CGFloat { max(0, width) * max(0, height) } }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
