import AppKit
import ApplicationServices
import EdgeStashCore

extension AppDelegate {
    func stopActivity() {
        timer?.invalidate(); timer = nil; pollingInterval = nil
        pointerWork?.cancel(); pointerWork = nil
        raiseWork?.cancel(); raiseWork = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
        removeFocusObserver(); stopEscape()
    }

    func updateActivity() {
        guard !isSleeping, !entries.isEmpty else { stopActivity(); return }
        if globalMouseMonitor == nil {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.pointerChanged(event) }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.pointerChanged(event); return event
            }
        }
        let interval = entries.contains(where: { $0.revealed }) ? 0.12 : 0.5
        if pollingInterval != interval {
            timer?.invalidate(); pollingInterval = interval
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = interval / 4
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        configureFocusObserver()
        if preferences.dismissMode == .escape, escapeTap == nil, AXIsProcessTrusted() { configureEscape() }
        requestPointerTick()
    }

    func pointerChanged(_ event: NSEvent) {
        requestPointerTick()
        if event.type == .leftMouseDown || event.type == .leftMouseUp { schedulePinRaise() }
    }

    func requestPointerTick(after delay: Double = 0.02) {
        guard !isSleeping, !entries.isEmpty, pointerWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pointerWork = nil; self?.tick() }
        pointerWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func removeFocusObserver() {
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes) }
        focusObserver = nil; observedPID = nil
    }

    func configureFocusObserver() {
        guard !isSleeping, preferences.dismissMode == .escape, entries.contains(where: { $0.revealed }),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { removeFocusObserver(); return }
        guard observedPID != pid else { return }
        removeFocusObserver()
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, context in
            guard let context else { return }
            let controller = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let focused = elementAttribute(element, kAXFocusedWindowAttribute),
               controller.activeEntries.contains(where: { $0.revealed && CFEqual($0.element, focused) }) { return }
            controller.schedulePinRaise()
        }, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        focusObserver = observer; observedPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func schedulePinRaise() {
        guard !isSleeping, preferences.dismissMode == .escape, entries.contains(where: { $0.revealed }), raiseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.raiseWork = nil
            guard !self.isSleeping, self.preferences.dismissMode == .escape,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pinned = self.activeEntries.filter { $0.revealed && $0.animation == nil }
            for entry in pinned.filter({ $0 !== self.lastRevealed }) + pinned.filter({ $0 === self.lastRevealed }) {
                // Raise without activating the app, preserving keyboard focus in the clicked window.
                let result = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
                if result != .success, result != .invalidUIElement {
                    let message = "\(entry.appName) refused to stay above other windows. Use Escape or Hide to return it to the stash."
                    if self.lastError != message { self.report(message) }
                }
            }
        }
        raiseWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    @objc func systemWillSleep() {
        guard !isSleeping else { return }
        isSleeping = true; stopActivity(); hoverIntent.cancel()
        for entry in entries {
            let wasAnimating = entry.animation != nil
            entry.animation?.invalidate(); entry.animation = nil
            if wasAnimating, let actual = try? frame(of: entry.element) { entry.geometry.didPresent(actual) }
            if entry.revealed || wasAnimating { perform { try hide(entry, animated: false) } }
            entry.tab.orderOut(nil)
        }
    }

    @objc func systemDidWake() {
        guard isSleeping else { return }
        isSleeping = false
        let point = NSEvent.mouseLocation
        hoverIntent.cancel(blocking: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        nextMaintenance = 0; nextGeometryCheck = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isSleeping else { return }
            self.registerShortcuts()
            if AXIsProcessTrusted() { self.configureEscape() }
            if self.entries.contains(where: { !self.screens.contains($0.screen) }) { self.restoreAll() }
            else {
                var scopes = Set<ObjectIdentifier>()
                for entry in self.entries where scopes.insert(ObjectIdentifier(entry.scope)).inserted {
                    if !entry.scope.marker.isVisible { entry.scope.marker.orderFrontRegardless() }
                }
                self.layoutTabs()
            }
            self.updateActivity()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { stopActivity() }
}
