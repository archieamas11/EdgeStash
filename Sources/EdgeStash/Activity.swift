import AppKit
import ApplicationServices
import EdgeStashCore

extension AppDelegate {
    func stopActivity() {
        timer?.invalidate(); timer = nil; pollingInterval = nil
        pointerWork?.cancel(); pointerWork = nil
        raiseWork?.cancel(); raiseWork = nil
        wakeRecoveryWork?.cancel(); wakeRecoveryWork = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
        removeFocusObserver(); stopEscape()
    }

    func updateActivity() {
        guard !isSleeping, !entries.isEmpty else { stopActivity(); return }
        if globalMouseMonitor == nil {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
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
        guard !isSleeping, wakeRecoveryWork == nil else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            draggedEntry = nil; dragEndedAt = nil
            dragCandidate = activeEntries.first(where: { $0.revealed && !$0.isTransitioning
                && flip($0.geometry.displayedFrame, primaryHeight: primaryHeight).contains(point) && stashHasFocus($0) })
        case .leftMouseDragged:
            if let dragCandidate { draggedEntry = dragCandidate; dragEndedAt = nil }
        case .leftMouseUp:
            dragCandidate = nil
            dragEndedAt = Date()
        default: break
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            let targets = outsideClickTargets(at: point)
            // Let the outside click reach its destination before checking who owns focus.
            if !targets.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isSleeping, self.wakeRecoveryWork == nil, self.preferences.dismissMode != .escape else { return }
                    for entry in targets where entry.revealed && entry.scope.isActive && self.entries.contains(where: { $0 === entry }) {
                        self.perform { try self.hide(entry) }
                    }
                }
            }
        }
        requestPointerTick()
        if event.type == .leftMouseDown || event.type == .leftMouseUp { schedulePinRaise() }
    }

    func outsideClickTargets(at point: CGPoint) -> [StashedWindow] {
        guard !isSleeping, wakeRecoveryWork == nil, preferences.dismissMode != .escape else { return [] }
        let active = activeEntries
        // Indicator clicks keep stacks stable while revealing or cycling another window.
        if active.contains(where: { $0.tab.isVisible && $0.tab.frame.contains(point) }) { return [] }
        return active.filter { entry in
            guard entry.revealed else { return false }
            if entry.isTransitioning && entry.revealTriggerFrame?.contains(point) == true { return false }
            let frame = entry.isTransitioning
                ? ((entry.animation != nil ? try? frame(of: entry.element) : nil) ?? presentationFrame(for: entry))
                : entry.geometry.displayedFrame
            return !flip(frame, primaryHeight: primaryHeight).contains(point)
        }
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

    var pinnedFocusTarget: StashedWindow? {
        guard !isSleeping, preferences.dismissMode == .escape else { return nil }
        let candidates = activeEntries.filter { $0.revealed && !$0.isTransitioning }
        return candidates.first(where: { $0 === lastRevealed }) ?? candidates.last
    }

    func schedulePinRaise() {
        guard !isSleeping, preferences.dismissMode == .escape, entries.contains(where: { $0.revealed }), raiseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.raiseWork = nil
            guard !self.isSleeping, self.preferences.dismissMode == .escape,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pinned = self.activeEntries.filter { $0.revealed && !$0.isTransitioning }
            for entry in pinned.filter({ $0 !== self.lastRevealed }) + pinned.filter({ $0 === self.lastRevealed }) {
                let result = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
                if result != .success, result != .invalidUIElement {
                    let message = "\(entry.appName) refused to stay above other windows. Use Escape or Hide to return it to the stash."
                    if self.lastError != message { self.report(message) }
                }
            }
            if let target = self.pinnedFocusTarget {
                let application = AXUIElementCreateApplication(target.recovery.pid)
                let focused = elementAttribute(application, kAXFocusedWindowAttribute)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.recovery.pid
                    || focused.map({ !CFEqual($0, target.element) }) != false {
                    self.focusWindow(target)
                }
            }
        }
        raiseWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    @objc func systemWillSleep() {
        guard !isSleeping else { return }
        isSleeping = true; stopActivity(); hoverIntent.cancel()
        displayRecoveryWork?.cancel(); displayRecoveryWork = nil
        dragCandidate = nil; draggedEntry = nil; dragEndedAt = nil
        for entry in entries {
            entry.previousFocus = nil
            entry.invalidWindowChecks = 0
            if entry.revealed || entry.isTransitioning {
                perform { try hide(entry, animated: false, returnFocus: false, preserveStash: true) }
            }
            entry.tab.orderOut(nil)
        }
    }

    @objc func systemDidWake() {
        // Screen and system wake notifications can arrive separately or without a matching sleep callback.
        isSleeping = false
        wakeRecoveryWork?.cancel(); wakeRecoveryWork = nil
        displayRecoveryWork?.cancel(); displayRecoveryWork = nil
        let point = NSEvent.mouseLocation
        hoverIntent.cancel(blocking: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        nextMaintenance = 0; nextGeometryCheck = 0; nextWorkAreaCheck = 0
        reconcileWake(attempt: 0)
    }

    func reconcileWake(attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSleeping else { return }
            self.wakeRecoveryWork = nil
            if attempt == 0 { self.registerShortcuts() }
            if AXIsProcessTrusted(), self.escapeTap == nil { self.configureEscape() }
            for entry in self.entries {
                entry.invalidWindowChecks = 0
                if !entry.scope.marker.isVisible { entry.scope.marker.orderFrontRegardless() }
            }
            self.reconcileDisplays(restoreDisconnected: attempt == 2)
            // A missed sleep notification can leave a reveal in progress when the session resumes.
            for entry in self.activeEntries where entry.revealed || entry.isTransitioning {
                self.perform { try self.hide(entry, animated: false, returnFocus: false, preserveStash: true) }
            }
            self.reconcileStashes()
            self.updateActivity()
            if attempt < 2 && !self.entries.isEmpty { self.reconcileWake(attempt: attempt + 1) }
        }
        wakeRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.6 : 1.2), execute: work)
    }

    func applicationWillTerminate(_ notification: Notification) { stopActivity() }
}
