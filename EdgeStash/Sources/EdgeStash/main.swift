import AppKit
import ApplicationServices
import Carbon
import Darwin
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

func applicationLaunchDate(_ app: NSRunningApplication?) -> Date? {
    guard let app, !app.isTerminated else { return nil }
    if let date = app.launchDate { return date }
    // Finder and some system apps omit AppKit's date; keep PID reuse protection using the kernel start time.
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard app.processIdentifier > 0,
          proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
          info.pbi_pid == UInt32(app.processIdentifier), info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
}

func dockItemFrames() -> [CGRect]? {
    guard AXIsProcessTrusted(),
          let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.02)
    guard let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    let frames: [CGRect] = children.compactMap { list in
        AXUIElementSetMessagingTimeout(list, 0.02)
        guard attribute(list, kAXRoleAttribute) as? String == kAXListRole,
              let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement],
              let first = items.first, let last = items.last else { return nil }
        // Dock list order follows its icons; endpoints bound the visible strip, not its screen-sized backing window.
        AXUIElementSetMessagingTimeout(first, 0.02); AXUIElementSetMessagingTimeout(last, 0.02)
        guard let leading = try? frame(of: first), let trailing = try? frame(of: last) else { return nil }
        return leading.union(trailing).insetBy(dx: -8, dy: -8)
    }
    return frames.isEmpty ? nil : frames
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
    var original: CGRect
}

final class StashedWindow {
    let indicatorID = UUID().uuidString
    let element: AXUIElement
    var recovery: Recovery
    var edge: Edge
    let screen: CGRect
    let tab: TabPanel
    let scope: StashScope
    let brandColor: NSColor?
    var geometry: WindowGeometry
    var monitorGeometryAfter = Date.distantFuture
    var pendingMoveSince: Date?
    var revealTriggerFrame: CGRect?
    var noteFrame: CGRect?
    var indicatorEntrancePending = true
    let appID: String
    let appName: String
    var animation: Timer?
    var imageSlide: WindowImageSlide?
    var isTransitioning: Bool { animation != nil || imageSlide != nil }
    var revealed = false
    var minimized = false
    var leftSince: Date?

    init(element: AXUIElement, recovery: Recovery, edge: Edge, screen: CGRect, tab: TabPanel, scope: StashScope) {
        self.element = element; self.recovery = recovery; self.edge = edge; self.screen = screen; self.tab = tab
        self.scope = scope
        geometry = WindowGeometry(original: recovery.original)
        let app = NSRunningApplication(processIdentifier: recovery.pid)
        brandColor = dominantAppIconColor(app?.icon)
        appID = app?.bundleIdentifier ?? app?.executableURL?.path ?? String(recovery.pid)
        appName = app?.localizedName ?? "Application"
    }
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
    var activeEntries: [StashedWindow] { entries.filter { $0.scope.isActive } }
    var lastLayoutMembers: Set<ObjectIdentifier> = []
    var lastLayoutWorkAreas: [CGRect] = []
    var nextWorkAreaCheck = 0.0
    var dockFrames: [CGRect] = []
    var probesDock = false
    var hoverIntent = HoverIntent<ObjectIdentifier>()
    var pointerWork: DispatchWorkItem?
    var raiseWork: DispatchWorkItem?
    var globalMouseMonitor: Any?
    var localMouseMonitor: Any?
    var focusObserver: AXObserver?
    var observedPID: pid_t?
    var pollingInterval: Double?
    var nextGeometryCheck = 0.0
    var nextMaintenance = 0.0
    var isSleeping = false
    var visibleIndicatorIDs: Set<ObjectIdentifier> = []
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
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        if AXIsProcessTrusted() { recoverWindows() }
        if CommandLine.arguments.contains("--settings") || UserDefaults.standard.data(forKey: preferencesKey) == nil { showSettings() }
    }

    @objc func frontmostChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastFrontmost = app }
        if preferences.dismissMode == .escape, escapeTap == nil, AXIsProcessTrusted() { configureEscape() }
        configureFocusObserver()
        schedulePinRaise()
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
        for (index, entry) in entries.enumerated() where entry.scope.isActive {
            if entry.revealed {
                let hide = add("Hide \(entry.recovery.title.isEmpty ? entry.appName : entry.recovery.title) to Stash", action: #selector(hideMenuEntry(_:)), to: menu)
                hide.representedObject = entry
            }
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
        guard let app = NSRunningApplication(processIdentifier: pid), let launched = applicationLaunchDate(app) else {
            throw StashError.message("The window's application is no longer running.")
        }
        let record = Recovery(pid: pid, launched: launched, title: attribute(window, kAXTitleAttribute) as? String ?? "", original: original)
        let tab = TabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tab.isOpaque = false; tab.backgroundColor = .clear; tab.hasShadow = false
        tab.hidesOnDeactivate = false
        tab.collectionBehavior = [.stationary, .ignoresCycle]
        let button = IndicatorButton(title: "", target: self, action: #selector(tabClicked(_:)))
        button.isBordered = false
        button.icon = app.icon
        button.toolTip = "\(app.localizedName ?? "Application") — hover to reveal, click to cycle; Shift-drag to move; right-click for windows"
        button.setAccessibilityLabel("Reveal \(app.localizedName ?? "stashed window")")
        tab.contentView = button
        let scope = entries.first(where: { $0.screen == screen && $0.scope.isActive })?.scope
            ?? StashScope(screen: flip(screen, primaryHeight: primaryHeight))
        let entry = StashedWindow(element: window, recovery: record, edge: edge, screen: screen, tab: tab, scope: scope)
        entries.append(entry)
        do {
            try saveJournal()
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

    func indicatorScreen(for entry: StashedWindow) -> CGRect {
        entry.edge == .top || entry.edge == .bottom ? entry.screen : visibleScreen(for: entry)
    }

    func topCutout(for entry: StashedWindow) -> CGRect? {
        guard let display = NSScreen.screens.first(where: { flip($0.frame, primaryHeight: primaryHeight) == entry.screen }),
              display.safeAreaInsets.top > 0,
              let leftArea = display.auxiliaryTopLeftArea, let rightArea = display.auxiliaryTopRightArea,
              !leftArea.isEmpty, !rightArea.isEmpty else { return nil }
        let left = flip(leftArea, primaryHeight: primaryHeight)
        let right = flip(rightArea, primaryHeight: primaryHeight)
        return CGRect(x: left.maxX, y: entry.screen.minY, width: max(0, right.minX - left.maxX), height: display.safeAreaInsets.top)
    }

    func refreshWorkAreas() -> Bool {
        let needsDock = activeEntries.contains { $0.edge == .bottom }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime >= nextWorkAreaCheck || needsDock != probesDock else { return false }
        nextWorkAreaCheck = uptime + 0.5; probesDock = needsDock
        let workAreas = NSScreen.screens.map(\.visibleFrame)
        let frames = needsDock ? (dockItemFrames() ?? dockFrames) : []
        let changed = workAreas != lastLayoutWorkAreas || frames != dockFrames
        lastLayoutWorkAreas = workAreas; dockFrames = frames
        return changed
    }

    func indicatorObstruction(for entry: StashedWindow) -> CGRect? {
        switch entry.edge {
        case .top: return topCutout(for: entry)
        case .bottom: return dockFrames.compactMap { bottomDockObstruction($0, screen: entry.screen) }.max { $0.width < $1.width }
        default: return nil
        }
    }

    func indicatorPanel(for entry: StashedWindow, bar: CGRect) -> CGRect {
        let panel = entry.edge.indicatorPanelFrame(bar: bar, showIcon: preferences.showAppIcon, iconSize: preferences.appIconSize)
        return entry.edge.avoidingObstruction(panel, screen: entry.screen, obstruction: indicatorObstruction(for: entry))
    }

    func presentationFrame(for entry: StashedWindow) -> CGRect {
        let indicator = entry.noteFrame.map { flip($0, primaryHeight: primaryHeight) }
        return entry.edge.revealedFrame(entry.geometry.displayedFrame, screen: visibleScreen(for: entry), indicator: indicator)
    }

    func slide(_ entry: StashedWindow, to destination: CGRect, animated: Bool = true, completion: @escaping (Error?) -> Void) {
        entry.animation?.invalidate(); entry.animation = nil
        guard animated, preferences.animate, !isSleeping, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let origin = try? frame(of: entry.element), !framesMatch(origin, destination) else {
            do { try move(entry.element, to: destination, resize: true); completion(nil) }
            catch { completion(error) }
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let duration = preferences.animationDuration
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak entry] timer in
            guard let entry else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
            do {
                try move(entry.element, to: entry.edge.windowSlideFrame(from: origin, to: destination, progress: progress), resize: progress >= 1)
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

    @discardableResult
    func observeUserGeometry(_ entry: StashedWindow, confirmMove: Bool = false) throws -> Bool {
        guard entry.revealed, !entry.isTransitioning else { return true }
        if attribute(entry.element, kAXMinimizedAttribute) as? Bool == true {
            entry.revealed = false; entry.minimized = true
            layoutTabs()
            return true
        }
        let actual = try frame(of: entry.element)
        switch entry.geometry.observe(actual) {
        case .none: entry.pendingMoveSince = nil
        case .resized:
            entry.pendingMoveSince = nil
            entry.recovery.original = entry.geometry.restoreFrame
            try saveJournal()
            layoutTabs()
        case .moved:
            guard entry.scope.isActive, confirmMove || Date() >= entry.monitorGeometryAfter else { return true }
            if confirmMove || entry.pendingMoveSince.map({ Date().timeIntervalSince($0) >= 0.15 }) == true {
                // A deliberate move leaves the window exactly where the user put it.
                try forget(entry)
                return false
            }
            if entry.pendingMoveSince == nil { entry.pendingMoveSince = Date() }
        }
        return true
    }

    func hide(_ entry: StashedWindow, animated: Bool = true) throws {
        let hadImageSlide = entry.imageSlide != nil
        MainActor.assumeIsolated { entry.imageSlide?.cancel(); entry.imageSlide = nil }
        if !hadImageSlide { guard try observeUserGeometry(entry, confirmMove: true) else { return } }
        let current = try frame(of: entry.element)
        entry.revealed = false; entry.leftSince = nil
        entry.indicatorEntrancePending = true
        if let note = entry.noteFrame, note.contains(NSEvent.mouseLocation) { hoverIntent.cancel(blocking: note.insetBy(dx: -2, dy: -2)) }
        entry.revealTriggerFrame = nil
        entry.monitorGeometryAfter = .distantFuture
        if shouldUseImageSlide(entry, animated: animated), !windowIsHidden(current, on: screens) {
            hideWithImageSlide(entry, from: current)
            layoutTabs()
            return
        }
        conceal(entry, from: current, animated: animated)
    }

    func conceal(_ entry: StashedWindow, from current: CGRect, animated: Bool) {
        let destination = entry.edge.hiddenFrame(current, screen: entry.screen)
        slide(entry, to: destination, animated: animated) { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            defer { self.layoutTabs() }
            if let actual = try? frame(of: entry.element), windowIsHidden(actual, on: self.screens) {
                entry.minimized = false
                return
            }
            // Menu bar and Dock clamping can leave a strip; try a safe sideways corner first.
            let window = current
            for corner in entry.edge.cornerFallbacks(window, screen: entry.screen, others: self.screens.filter { $0 != entry.screen }) {
                if (try? move(entry.element, to: corner)) != nil,
                   let actual = try? frame(of: entry.element), windowIsHidden(actual, on: self.screens) {
                    entry.minimized = false
                    return
                }
            }
            do {
                // shortcut: macOS clamps some edges; use native minimization when a full offscreen slide is unavailable.
                try minimize(entry.element, true)
                entry.minimized = true
            } catch {
                entry.revealed = true
                entry.geometry.didPresent((try? frame(of: entry.element)) ?? self.presentationFrame(for: entry))
                entry.monitorGeometryAfter = Date().addingTimeInterval(0.15)
                self.report("Could not hide \(entry.appName): \(error.localizedDescription). Use its restore action.")
            }
        }
        layoutTabs()
    }

    func focusWindow(_ entry: StashedWindow) {
        guard entry.scope.isActive else { return }
        NSRunningApplication(processIdentifier: entry.recovery.pid)?.activate(options: [])
        let app = AXUIElementCreateApplication(entry.recovery.pid)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, entry.element)
        _ = AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
    }

    func reveal(_ entry: StashedWindow, animated: Bool = true) throws {
        guard entry.scope.isActive, !entry.revealed, entry.imageSlide == nil, !isSleeping else { return }
        if preferences.stackByApp {
            for other in stack(for: entry) where other !== entry && other.revealed {
                try hide(other)
            }
        }
        entry.animation?.invalidate(); entry.animation = nil
        let destination = presentationFrame(for: entry)
        if shouldUseImageSlide(entry, animated: animated) {
            entry.revealed = true; entry.leftSince = nil
            entry.revealTriggerFrame = stack(for: entry).first?.noteFrame
            entry.pendingMoveSince = nil; entry.monitorGeometryAfter = .distantFuture
            hoverIntent.cancel(blocking: entry.revealTriggerFrame)
            lastRevealed = entry
            revealWithImageSlide(entry, to: destination)
            layoutTabs()
            return
        }
        let origin = entry.edge.hiddenFrame(destination, screen: entry.screen)
        if entry.minimized { try? move(entry.element, to: origin) }
        try minimize(entry.element, false)
        // Rebase from an old note/corner before focusing; readback in slide respects macOS edge clamping.
        try move(entry.element, to: origin)
        entry.minimized = false
        entry.revealed = true; entry.leftSince = nil
        entry.revealTriggerFrame = stack(for: entry).first?.noteFrame
        entry.pendingMoveSince = nil; entry.monitorGeometryAfter = .distantFuture
        hoverIntent.cancel(blocking: entry.revealTriggerFrame)
        lastRevealed = entry
        focusWindow(entry)
        slide(entry, to: destination, animated: animated) { [weak self, weak entry] error in
            guard let self, let entry else { return }
            if let error {
                entry.revealed = false
                self.hoverIntent.cancel(blocking: entry.noteFrame)
                self.report(error.localizedDescription)
            } else {
                entry.geometry.didPresent((try? frame(of: entry.element)) ?? self.presentationFrame(for: entry))
                entry.monitorGeometryAfter = Date().addingTimeInterval(0.15)
                self.schedulePinRaise()
            }
            self.layoutTabs()
        }
        layoutTabs()
    }

    func forget(_ entry: StashedWindow) throws {
        try saveJournal(excluding: entry)
        entry.animation?.invalidate(); entry.animation = nil
        MainActor.assumeIsolated { entry.imageSlide?.cancel(); entry.imageSlide = nil }
        entry.tab.close()
        entries.removeAll { $0 === entry }
        if !entries.contains(where: { $0.scope === entry.scope }) { entry.scope.marker.close() }
        if lastRevealed === entry { lastRevealed = nil }
        var value = preferences
        value.indicatorAnchors = value.indicatorAnchors.filter { !$0.key.hasPrefix("\(entry.appID)|\(entry.indicatorID)|") }
        if value != preferences { applyPreferences(value) } else { layoutTabs() }
        refreshSettings()
    }

    func restore(_ entry: StashedWindow) throws {
        let wasAnimating = entry.isTransitioning
        entry.animation?.invalidate(); entry.animation = nil
        MainActor.assumeIsolated { entry.imageSlide?.cancel(); entry.imageSlide = nil }
        if entry.revealed && !wasAnimating { guard try observeUserGeometry(entry, confirmMove: true) else { return } }
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(entry.element, kAXRoleAttribute as CFString, &role)
        if status != .invalidUIElement,
           applicationLaunchDate(NSRunningApplication(processIdentifier: entry.recovery.pid)) == entry.recovery.launched {
            try minimize(entry.element, false)
            let destination = restoreFrame(entry.geometry.restoreFrame)
            try move(entry.element, to: destination, resize: true)
        }
        try forget(entry)
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
        let current = members.firstIndex(where: { $0.revealed }) ?? members.firstIndex(where: { $0 === lastRevealed })
        let next = members[((current ?? -1) + 1) % members.count]
        perform { try reveal(next) }
    }

    @objc func revealMenuEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? StashedWindow, entries.contains(where: { $0 === entry }) else { return }
        perform { try reveal(entry) }
    }

    @objc func restoreMenuEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? StashedWindow, entries.contains(where: { $0 === entry }) else { return }
        perform { try restore(entry) }
    }

    @objc func hideMenuEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? StashedWindow, entries.contains(where: { $0 === entry }) else { return }
        perform { try hide(entry) }
    }

    func cycleStack() {
        guard let current = lastRevealed, current.scope.isActive else { return }
        let members = stack(for: current)
        guard let index = members.firstIndex(where: { $0 === current }), !members.isEmpty else { return }
        perform { try reveal(members[(index + 1) % members.count]) }
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
    @objc func displaysChanged() {
        if isSleeping { return }
        // Display notifications during wake settle before window restoration is evaluated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isSleeping else { return }
            if self.entries.contains(where: { !self.screens.contains($0.screen) }) { self.restoreAll() }
            else { self.layoutTabs() }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        restoreAll()
        return entries.isEmpty ? .terminateNow : .terminateCancel
    }

    func indicatorGroups() -> [[StashedWindow]] {
        var groups: [[StashedWindow]] = []
        for entry in activeEntries {
            if preferences.stackByApp, let index = groups.firstIndex(where: {
                $0[0].appID == entry.appID && $0[0].edge == entry.edge && $0[0].screen == entry.screen
            }) { groups[index].append(entry) }
            else { groups.append([entry]) }
        }
        return groups
    }

    func anchorKey(for entry: StashedWindow) -> String {
        let screenID = NSScreen.screens.first(where: { flip($0.frame, primaryHeight: primaryHeight) == entry.screen })?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let identity = preferences.stackByApp ? entry.appID : "\(entry.appID)|\(entry.indicatorID)"
        return "\(identity)|\(screenID?.stringValue ?? String(describing: entry.screen.minX))|\(entry.edge.rawValue)"
    }

    func layoutTabs() {
        if isSleeping { entries.forEach { $0.tab.orderOut(nil) }; stopActivity(); return }
        let active = activeEntries
        lastLayoutMembers = Set(active.map { ObjectIdentifier($0) })
        _ = refreshWorkAreas()
        // Open stacks keep their slots so remaining hover targets never shift during a reveal.
        let groups = indicatorGroups()
        let visible = groups.filter { !$0.contains(where: { $0.revealed || $0.isTransitioning }) }
        visibleIndicatorIDs = Set(visible.map { ObjectIdentifier($0[0]) })
        for entry in entries where !visibleIndicatorIDs.contains(ObjectIdentifier(entry)) { entry.tab.orderOut(nil) }
        for group in groups {
            let entry = group[0]
            let peers = groups.filter { $0[0].edge == entry.edge && $0[0].screen == entry.screen }
            let index = peers.firstIndex(where: { $0[0] === entry }) ?? 0
            let anchors = peers.map { preferences.indicatorAnchors[anchorKey(for: $0[0])] }
            let screen = indicatorScreen(for: entry)
            let automaticScreen = entry.edge.avoidingObstruction(screen, screen: entry.screen, obstruction: indicatorObstruction(for: entry))
            let automaticBars = entry.edge.tabFrames(screen: automaticScreen, count: peers.count,
                length: preferences.indicatorHeight, width: preferences.indicatorWidth, gap: preferences.indicatorGap)
            let anchoredBars = entry.edge.tabFrames(screen: screen, count: peers.count,
                length: preferences.indicatorHeight, width: preferences.indicatorWidth, gap: preferences.indicatorGap, anchors: anchors)
            let panel = indicatorPanel(for: entry, bar: anchors[index] == nil ? automaticBars[index] : anchoredBars[index])
            let cocoaFrame = flip(panel, primaryHeight: primaryHeight)
            group.forEach { $0.noteFrame = cocoaFrame }
            if (entry.tab.contentView as? IndicatorButton)?.isDragging != true {
                if !preferences.animate || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { entry.tab.cancelEntrance() }
                entry.tab.place(at: cocoaFrame)
            }
            if let button = entry.tab.contentView as? IndicatorButton {
                button.count = group.count; button.edge = entry.edge
                button.thickness = preferences.indicatorWidth; button.showIcon = preferences.showAppIcon
                button.iconSize = preferences.appIconSize; button.usesGlass = preferences.glassIndicators
                button.cornerRadius = preferences.indicatorCornerRadius
                button.tint = preferences.appColors[entry.appID].map(colorFromHex)
                    ?? (preferences.useAppBrandColor ? entry.brandColor : nil) ?? colorFromHex(preferences.indicatorColor)
                button.needsLayout = true; button.needsDisplay = true
                let menu = NSMenu()
                for member in group {
                    let item = NSMenuItem(title: "Reveal \(member.recovery.title.isEmpty ? member.appName : member.recovery.title)", action: #selector(revealMenuEntry(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = member; menu.addItem(item)
                    let restore = NSMenuItem(title: "Unstash \(member.recovery.title.isEmpty ? member.appName : member.recovery.title)", action: #selector(restoreMenuEntry(_:)), keyEquivalent: "")
                    restore.target = self; restore.representedObject = member; menu.addItem(restore)
                }
                button.menu = menu
                button.onMoveStarted = { [weak self, weak entry] in
                    if let self, let entry {
                        self.hoverIntent.cancel(blocking: entry.noteFrame ?? entry.tab.frame)
                        entry.tab.cancelEntrance()
                        entry.tab.orderFrontRegardless()
                    }
                }
                button.onDragChanged = { [weak self, weak entry] point in
                    if let self, let entry { self.dragIndicator(entry, center: point, finished: false) }
                }
                button.onDragEnded = { [weak self, weak entry] point in
                    if let self, let entry { self.dragIndicator(entry, center: point, finished: true) }
                }
                button.setAccessibilityLabel("\(entry.appName), \(group.count) stashed window\(group.count == 1 ? "" : "s"). Click to reveal or cycle; hold Shift and drag along the edge to move.")
            }
            if visibleIndicatorIDs.contains(ObjectIdentifier(entry)) {
                let animate = group.contains(where: { $0.indicatorEntrancePending }) && preferences.animate
                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                group.forEach { $0.indicatorEntrancePending = false }
                if !entry.tab.isVisible {
                    let origin = flip(entry.edge.hiddenFrame(panel, screen: entry.screen, sliver: 0), primaryHeight: primaryHeight)
                    entry.tab.present(at: cocoaFrame, from: animate ? origin : nil, duration: preferences.animationDuration)
                }
            }
        }
        updateActivity()
    }

    func dragIndicator(_ entry: StashedWindow, center: CGPoint, finished: Bool) {
        hoverIntent.cancel(blocking: entry.tab.frame)
        let point = flip(CGRect(origin: center, size: .zero), primaryHeight: primaryHeight).origin
        let screen = indicatorScreen(for: entry)
        let neighbors = indicatorGroups().filter { $0[0] !== entry && $0[0].edge == entry.edge && $0[0].screen == entry.screen }
            .compactMap { $0[0].noteFrame }.map { flip($0, primaryHeight: primaryHeight) }
        let anchor = entry.edge.magneticAnchor(point: point, screen: screen, length: preferences.indicatorHeight, neighbors: neighbors)
        let bar = entry.edge.tabFrames(screen: screen, count: 1, length: preferences.indicatorHeight,
            width: preferences.indicatorWidth, gap: 0, anchors: [anchor])[0]
        let panel = indicatorPanel(for: entry, bar: bar)
        let frame = flip(panel, primaryHeight: primaryHeight)
        entry.tab.setFrame(frame, display: true)
        if finished {
            var value = preferences
            let vertical = entry.edge == .left || entry.edge == .right
            let extent = vertical ? screen.height : screen.width
            let position = vertical ? panel.midY - screen.minY : panel.midX - screen.minX
            value.indicatorAnchors[anchorKey(for: entry)] = extent > 0 ? Double(position / extent) : 0.5
            applyPreferences(value)
            entry.tab.orderFrontRegardless()
            hoverIntent.cancel(blocking: frame.insetBy(dx: -4, dy: -4))
        }
    }

    @objc func spaceChanged() {
        let point = NSEvent.mouseLocation
        hoverIntent.cancel(blocking: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        for entry in entries where entry.revealed { perform { try hide(entry) } }
        layoutTabs()
        // Mission Control updates membership asynchronously; repair indicators again after it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.layoutTabs(); self?.refreshSettings()
        }
    }

    @objc func tick() {
        guard !isSleeping, !entries.isEmpty else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime >= nextMaintenance {
            nextMaintenance = uptime + 2
            guard AXIsProcessTrusted() else { return }
            var launches: [pid_t: Date] = [:]
            for entry in entries {
                if launches[entry.recovery.pid] == nil { launches[entry.recovery.pid] = applicationLaunchDate(NSRunningApplication(processIdentifier: entry.recovery.pid)) }
                if launches[entry.recovery.pid] != entry.recovery.launched { perform { try forget(entry) } }
            }
        }
        let active = activeEntries
        if refreshWorkAreas() { layoutTabs() }
        if Set(active.map { ObjectIdentifier($0) }) != lastLayoutMembers ||
           entries.contains(where: { visibleIndicatorIDs.contains(ObjectIdentifier($0)) && !$0.tab.isVisible }) { layoutTabs() }
        let point = NSEvent.mouseLocation
        let now = Date()
        let mouseDown = NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.shift)
        let transitioning = active.contains { $0.isTransitioning || $0.tab.isSliding }
        let indicators = active.filter { $0.tab.isVisible }.map { $0.tab.frame }
            + active.filter { $0.revealed }.compactMap { $0.revealTriggerFrame }
        if uptime >= nextGeometryCheck {
            nextGeometryCheck = uptime + 0.12
            for entry in active where entry.revealed && !entry.isTransitioning {
                do { _ = try observeUserGeometry(entry) }
                catch {
                    var role: CFTypeRef?
                    if AXUIElementCopyAttributeValue(entry.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
                        perform { try forget(entry) }
                    } else if lastError != error.localizedDescription { report(error.localizedDescription) }
                }
            }
        }
        let ranks = Dictionary(uniqueKeysWithValues: NSApp.orderedWindows.enumerated().map { ($0.element.windowNumber, $0.offset) })
        let targets = active.filter { !$0.revealed && $0.tab.isVisible }
            .sorted { (ranks[$0.tab.windowNumber] ?? Int.max) < (ranks[$1.tab.windowNumber] ?? Int.max) }
            .map { (id: ObjectIdentifier($0), frame: $0.tab.frame) }
        if !preferences.openOnHover { hoverIntent.cancel() }
        if preferences.openOnHover, let identifier = hoverIntent.target(pointer: point, targets: targets, now: uptime, delay: preferences.showDelay,
            transitioning: transitioning, mouseDown: mouseDown), let leader = active.first(where: { ObjectIdentifier($0) == identifier }) {
            let selected = stack(for: leader).first(where: { $0 === lastRevealed }) ?? leader
            perform { try reveal(selected) }
            return
        }
        if hoverIntent.isWaiting { requestPointerTick() }
        guard preferences.dismissMode == .pointerLeaves, !mouseDown, !transitioning else { return }
        for entry in active where entries.contains(where: { $0 === entry }) && entry.revealed && entry.pendingMoveSince == nil {
            let window = flip(entry.geometry.displayedFrame, primaryHeight: primaryHeight).insetBy(dx: -12, dy: -12)
            if stashKeepsOpen(pointer: point, window: window, trigger: entry.revealTriggerFrame, indicators: indicators) { entry.leftSince = nil }
            else {
                if entry.leftSince == nil { entry.leftSince = now }
                if now.timeIntervalSince(entry.leftSince!) >= preferences.hideDelay { perform { try hide(entry) } }
            }
        }
    }

    @objc func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(preferences: preferences,
                onChange: { [weak self] in self?.applyPreferences($0) },
                onEnableAccessibility: { [weak self] in self?.enableAccessibility() },
                onRestoreAll: { [weak self] in self?.restoreAll() },
                onEnableScreenRecording: { [weak self] in self?.enableScreenRecording() })
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
            if old.dismissMode != value.dismissMode { configureEscape(); configureFocusObserver(); schedulePinRaise() }
            if old.enabled && !value.enabled { restoreAll() }
            layoutTabs()
        } catch { report("Settings could not be saved: \(error.localizedDescription)") }
    }

    func stopEscape() {
        if let escapeTap { CFMachPortInvalidate(escapeTap) }
        if let escapeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeSource, .commonModes) }
        escapeTap = nil; escapeSource = nil
    }

    func configureEscape() {
        stopEscape()
        guard preferences.dismissMode == .escape, !entries.isEmpty, !isSleeping else { return }
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
        guard !isSleeping, preferences.dismissMode == .escape, settingsController?.window?.isKeyWindow != true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let pinned = activeEntries.filter { $0.revealed }
        guard let entry = pinned.first(where: { $0 === lastRevealed }) ?? pinned.last else { return false }
        // Keep cross-process window work out of the keyboard event-tap callback.
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry, !self.isSleeping, entry.revealed, self.entries.contains(where: { $0 === entry }) else { return }
            self.perform { try self.hide(entry) }
        }
        return true
    }

    func saveJournal(excluding entry: StashedWindow? = nil) throws {
        guard journalReadable else { throw StashError.message("Repair or move the unreadable recovery.json file before stashing more windows; it has been preserved.") }
        let folder = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(recovery + entries.filter { $0 !== entry }.map(\.recovery)).write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    @objc func recoverWindows() {
        guard AXIsProcessTrusted() else { return }
        var remaining: [Recovery] = []
        for record in recovery {
            guard let app = NSRunningApplication(processIdentifier: record.pid), applicationLaunchDate(app) == record.launched else { continue }
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
