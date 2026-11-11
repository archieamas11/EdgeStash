import AppKit
import ApplicationServices
import EdgeStashCore

@main struct RuntimeChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            precondition(applicationLaunchDate(finder) != nil, "Finder must remain stashable when AppKit omits its launch date")
            precondition(applicationLaunchDate(finder) == applicationLaunchDate(finder), "Finder process identity must remain stable for maintenance and restoration")
        }
        precondition(applicationLaunchDate(NSRunningApplication(processIdentifier: Int32.max)) == nil, "A missing process must never get a fabricated launch date")
        print("Passed Finder kernel-start identity and missing-process rejection checks.")
        let controller = AppDelegate()
        controller.preferences.stackByApp = false
        controller.preferences.animate = false
        let screen = NSScreen.main!.frame
        let scope = StashScope(screen: screen)
        let deadline = Date().addingTimeInterval(1)
        while !scope.isActive && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let record = Recovery(pid: ProcessInfo.processInfo.processIdentifier, launched: applicationLaunchDate(NSRunningApplication.current)!, title: "Disposable", original: CGRect(x: 100, y: 100, width: 400, height: 300))
        controller.entries = (0..<2).map { _ in
            let panel = TabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = IndicatorButton(title: "", target: nil, action: nil)
            return StashedWindow(element: AXUIElementCreateApplication(record.pid), recovery: record, edge: .left,
                screen: flip(screen, primaryHeight: controller.primaryHeight), tab: panel, scope: scope)
        }
        precondition(controller.anchorKey(for: controller.entries[0]) != controller.anchorKey(for: controller.entries[1]),
            "Unstacked windows from one app need independent movement anchors")
        controller.layoutTabs()
        precondition(controller.pollingInterval == 0.5, "Hidden stashes must use the slower maintenance timer")
        let remainingFrame = controller.entries[1].tab.frame
        controller.entries[0].revealed = true
        controller.layoutTabs()
        precondition(controller.entries[1].tab.frame == remainingFrame, "Opening a peer must not shift a hover target under the pointer")
        precondition(controller.pollingInterval == 0.12, "Revealed stashes must track geometry with a bounded cadence")
        controller.entries[0].revealed = false
        controller.preferences.indicatorGap = 40
        controller.preferences.indicatorAnchors[controller.anchorKey(for: controller.entries[0])] = 0.2
        controller.preferences.indicatorAnchors[controller.anchorKey(for: controller.entries[1])] = 0.6
        controller.layoutTabs()
        let neighborFrame = controller.entries[1].tab.frame
        let first = controller.entries[0]
        let visibleScreen = flip(controller.visibleScreen(for: first), primaryHeight: controller.primaryHeight)
        let proposed = CGPoint(x: visibleScreen.midX, y: visibleScreen.minY + visibleScreen.height * 0.73)
        let savedPreference = UserDefaults.standard.object(forKey: controller.preferencesKey)
        defer {
            if let savedPreference { UserDefaults.standard.set(savedPreference, forKey: controller.preferencesKey) }
            else { UserDefaults.standard.removeObject(forKey: controller.preferencesKey) }
        }
        controller.dragIndicator(first, center: proposed, finished: true)
        precondition(first.edge == .left && first.tab.frame.minX == visibleScreen.minX,
            "Repositioning must stay on its stashed edge despite horizontal pointer movement")
        precondition(abs(first.tab.frame.midY - proposed.y) <= 1,
            "A manually moved note must retain the requested vertical position")
        precondition(controller.entries[1].tab.frame == neighborFrame, "Moving a note must not push a neighboring note")
        let pointer = CGPoint(x: first.tab.frame.midX, y: first.tab.frame.midY)
        let targets = [(id: ObjectIdentifier(first), frame: first.tab.frame)]
        precondition(controller.hoverIntent.target(pointer: pointer, targets: targets, now: 0, delay: 0, transitioning: false, mouseDown: false) == nil,
            "Releasing a moved note must not immediately open its stash")
        _ = controller.hoverIntent.target(pointer: CGPoint(x: visibleScreen.midX, y: visibleScreen.maxY), targets: targets, now: 1, delay: 0, transitioning: false, mouseDown: false)
        precondition(controller.hoverIntent.target(pointer: pointer, targets: targets, now: 2, delay: 0, transitioning: false, mouseDown: false) == ObjectIdentifier(first),
            "Hover-to-open must resume after leaving and re-entering a moved note")
        let aligned = controller.presentationFrame(for: first)
        let note = flip(first.noteFrame!, primaryHeight: controller.primaryHeight)
        let usable = controller.visibleScreen(for: first)
        let expectedY = min(max(note.midY - aligned.height / 2, usable.minY), usable.maxY - aligned.height)
        precondition(abs(aligned.minY - expectedY) <= 1,
            "Revealed windows must follow a moved indicator while remaining inside usable screen bounds")
        for edge in [Edge.top, .bottom] {
            first.edge = edge
            if edge == .bottom && !AXIsProcessTrusted() {
                // Untrusted check executables use a Dock footprint fixture; the installed app reads real Accessibility items.
                controller.dockFrames = [CGRect(x: first.screen.minX + first.screen.width * 0.2, y: first.screen.maxY - 80, width: first.screen.width * 0.6, height: 80)]
                controller.probesDock = true
                controller.nextWorkAreaCheck = ProcessInfo.processInfo.systemUptime + 5
            }
            if edge == .bottom {
                precondition(controller.indicatorScreen(for: first) == first.screen,
                    "Bottom notes must use the physical bottom edge so they can sit beside the Dock")
            }
            controller.layoutTabs()
            let frame = flip(first.noteFrame!, primaryHeight: controller.primaryHeight)
            if edge == .top, let cutout = controller.topCutout(for: first) {
                precondition(!frame.intersects(cutout) && frame.minY == first.screen.minY, "Top notes must sit beside the camera cutout at the physical edge")
                controller.entries[1].edge = .top
                controller.layoutTabs()
                let peerBefore = controller.entries[1].tab.frame
                let proposed = flip(CGRect(origin: CGPoint(x: cutout.midX, y: cutout.minY), size: .zero), primaryHeight: controller.primaryHeight).origin
                controller.dragIndicator(first, center: proposed, finished: true)
                let savedFrame = first.tab.frame
                let safe = flip(savedFrame, primaryHeight: controller.primaryHeight)
                precondition(!safe.intersects(cutout) && safe.minY == first.screen.minY, "Dragging across the notch must stay on a safe side")
                controller.layoutTabs()
                precondition(first.tab.frame == savedFrame, "Saved anchors must retain their actual safe position after layout")
                precondition(controller.entries[1].tab.frame == peerBefore, "Dragging a top note must not displace its automatic neighbor")
                controller.entries[1].edge = .left
            } else {
                precondition(abs((edge == .top ? frame.minY : frame.maxY) - (edge == .top ? first.screen.minY : first.screen.maxY)) <= 1,
                    "Top and bottom notes must stay at their physical screen edges")
            }
            if edge == .bottom, controller.visibleScreen(for: first).maxY < first.screen.maxY - 8 {
                precondition(controller.indicatorObstruction(for: first) != nil, "A bottom Dock footprint must provide bounds for side placement")
            }
            if edge == .bottom, let dock = controller.indicatorObstruction(for: first) {
                precondition(!frame.intersects(dock), "Bottom notes must be beside the Dock footprint")
                let proposed = flip(CGRect(origin: CGPoint(x: dock.midX, y: first.screen.maxY), size: .zero), primaryHeight: controller.primaryHeight).origin
                controller.dragIndicator(first, center: proposed, finished: true)
                let dragged = flip(first.tab.frame, primaryHeight: controller.primaryHeight)
                precondition(dragged.maxY == first.screen.maxY && !dragged.intersects(dock), "Dragging across the Dock must clamp sideways, never above it")
            }
            precondition(first.tab.level.rawValue > Int(CGWindowLevelForKey(.mainMenuWindow)) && first.tab.level.rawValue > Int(CGWindowLevelForKey(.dockWindow)),
                "Stash indicators must be above the menu bar and Dock window levels")
            let shown = controller.presentationFrame(for: first)
            precondition(controller.visibleScreen(for: first).contains(shown), "Real app windows must still fit within usable bounds")
        }
        controller.stopActivity(); controller.entries.forEach { $0.tab.close() }; scope.marker.close()
        controller.entries = []; controller.updateActivity()
        precondition(controller.timer == nil && controller.globalMouseMonitor == nil && controller.localMouseMonitor == nil,
            "No-stash idle must remove timers and mouse monitors")
        let motionPanel = TabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for edge in Edge.allCases {
            let display = controller.screens[0]
            let target = edge.tabFrame(screen: display, index: 0, count: 1)
            let cocoaTarget = flip(target, primaryHeight: controller.primaryHeight)
            let origin = flip(edge.hiddenFrame(target, screen: display, sliver: 0), primaryHeight: controller.primaryHeight)
            motionPanel.present(at: cocoaTarget, from: origin, duration: 0.04)
            precondition(motionPanel.isSliding && framesMatch(motionPanel.frame, origin, tolerance: 1),
                "A return slide must start outside the screen without AppKit clamping it")
            motionPanel.place(at: cocoaTarget)
            precondition(motionPanel.isSliding, "Layout must not interrupt an in-progress return to the same slot")
            let deadline = Date().addingTimeInterval(0.5)
            while motionPanel.isSliding && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(!motionPanel.isSliding && framesMatch(motionPanel.frame, cocoaTarget, tolerance: 1),
                "A native note slide must finish at its exact reserved slot on all four edges")
        }
        motionPanel.present(at: CGRect(x: 0, y: 0, width: 30, height: 48), from: CGRect(x: -30, y: 0, width: 30, height: 48), duration: 1)
        motionPanel.cancelEntrance()
        precondition(!motionPanel.isSliding && motionPanel.isVisible, "Starting a drag must cancel the return slide without hiding the indicator")
        motionPanel.present(at: CGRect(x: 0, y: 0, width: 30, height: 48), from: CGRect(x: -30, y: 0, width: 30, height: 48), duration: 1)
        motionPanel.orderOut(nil)
        precondition(!motionPanel.isSliding && !motionPanel.isVisible, "Hidden indicators must cancel their return timers")
        motionPanel.close()
        let image = NSImage(size: CGSize(width: 32, height: 32))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let imageSlide = WindowImageSlide()
        let shown = CGRect(x: controller.screens[0].midX - 150, y: controller.screens[0].minY + 26, width: 300, height: 240)
        let hidden = Edge.top.hiddenFrame(shown, screen: controller.screens[0], sliver: 0)
        var prepared = false
        var completions = 0
        var finalImageFrame = CGRect.zero
        imageSlide.start(from: hidden, to: shown, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.12,
            capture: { pixels }, isValid: { true }, prepare: { prepared = true }, completion: { completed in
                precondition(completed && prepared, "The real-window handoff must occur after preparing and completing the image slide")
                finalImageFrame = imageSlide.imageView!.frame
                completions += 1
            })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(prepared && completions == 0 && imageSlide.panel?.ignoresMouseEvents == true,
            "The top stand-in must animate without intercepting clicks")
        precondition(imageSlide.panel!.contentView!.layer!.masksToBounds, "The stand-in must clip image content at the display boundary")
        precondition(imageSlide.panel!.frame.intersection(NSScreen.screens[0].frame) == imageSlide.panel!.frame,
            "The image viewport must stay on its originating display")
        precondition(imageSlide.imageView!.frame.maxY > imageSlide.panel!.frame.height,
            "A clamped top window must visibly enter from above instead of appearing at its destination")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(completions == 1 && finalImageFrame.origin == .zero, "The image must finish aligned with the real window")
        precondition(imageSlide.panel == nil && imageSlide.imageView == nil, "A completed slide must discard the window image and panel")
        var lateImage: CheckedContinuation<CGImage?, Never>?
        imageSlide.start(from: shown, to: hidden, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.04,
            capture: { await withCheckedContinuation { lateImage = $0 } }, isValid: { true }, prepare: {}, completion: { _ in preconditionFailure("Cancelled captures must never reopen a window") })
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        imageSlide.cancel(); lateImage!.resume(returning: pixels)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(imageSlide.panel == nil, "An image arriving after cancellation must be discarded")
        var valid = true
        var interrupted = false
        imageSlide.start(from: shown, to: hidden, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.2,
            capture: { pixels }, isValid: { valid }, prepare: {}, completion: { interrupted = !$0 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        valid = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(interrupted && imageSlide.panel == nil, "A Space or sleep interruption must remove the stand-in")
        var failedCapture = false
        imageSlide.start(from: hidden, to: shown, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.04,
            capture: { nil }, isValid: { true }, prepare: { preconditionFailure("An unavailable image must not conceal the real window") }, completion: { failedCapture = !$0 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(failedCapture && imageSlide.panel == nil, "Capture failure must return control to the ordinary reveal path")
        var captureTimeout = false
        var stalledCapture: CheckedContinuation<CGImage?, Never>?
        imageSlide.start(from: hidden, to: shown, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.04,
            capture: { await withCheckedContinuation { stalledCapture = $0 } }, isValid: { true }, prepare: { preconditionFailure("A timed-out image must not conceal a window") }, completion: { captureTimeout = !$0 })
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        precondition(captureTimeout && imageSlide.panel == nil, "A stalled capture must fall back without blocking window recovery")
        stalledCapture!.resume(returning: pixels)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(imageSlide.panel == nil, "A late timed-out capture must not display a panel")
        var failedPrepare = false
        imageSlide.start(from: shown, to: hidden, screen: controller.screens[0], primaryHeight: controller.primaryHeight, duration: 0.04,
            capture: { pixels }, isValid: { true }, prepare: { throw StashError.message("fixture") }, completion: { failedPrepare = !$0 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(failedPrepare && imageSlide.panel == nil, "A refused real-window move must discard the stand-in")
        print("Passed clipped top-edge image movement, real-window handoff, memory cleanup, cancellation, Space/sleep interruption, and capture-failure fallback checks.")
        controller.systemWillSleep()
        precondition(controller.isSleeping && controller.timer == nil && controller.pointerWork == nil)
        controller.systemDidWake()
        precondition(!controller.isSleeping && controller.nextMaintenance == 0)
        print("Passed actual note independence, edge movement, post-drag hover, window alignment, top/bottom layering, return slides, idle, and sleep/wake checks.")
    }
}
