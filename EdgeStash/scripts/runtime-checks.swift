import AppKit
import ApplicationServices
import EdgeStashCore

@main struct RuntimeChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppDelegate()
        controller.preferences.stackByApp = false
        let screen = NSScreen.main!.frame
        let scope = StashScope(screen: screen)
        let deadline = Date().addingTimeInterval(1)
        while !scope.isActive && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let record = Recovery(pid: ProcessInfo.processInfo.processIdentifier, launched: NSRunningApplication.current.launchDate ?? Date(), title: "Disposable", original: CGRect(x: 100, y: 100, width: 400, height: 300))
        controller.entries = (0..<2).map { _ in
            let panel = TabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = IndicatorButton(title: "", target: nil, action: nil)
            return StashedWindow(element: AXUIElementCreateApplication(record.pid), recovery: record, edge: .left,
                screen: flip(screen, primaryHeight: controller.primaryHeight), tab: panel, scope: scope)
        }
        controller.layoutTabs()
        precondition(controller.pollingInterval == 0.5, "Hidden stashes must use the slower maintenance timer")
        let remainingFrame = controller.entries[1].tab.frame
        controller.entries[0].revealed = true
        controller.layoutTabs()
        precondition(controller.entries[1].tab.frame == remainingFrame, "Opening a peer must not shift a hover target under the pointer")
        precondition(controller.pollingInterval == 0.12, "Revealed stashes must track geometry with a bounded cadence")
        controller.stopActivity(); controller.entries.forEach { $0.tab.close() }; scope.marker.close()
        controller.entries = []; controller.updateActivity()
        precondition(controller.timer == nil && controller.globalMouseMonitor == nil && controller.localMouseMonitor == nil,
            "No-stash idle must remove timers and mouse monitors")
        controller.systemWillSleep()
        precondition(controller.isSleeping && controller.timer == nil && controller.pointerWork == nil)
        controller.systemDidWake()
        precondition(!controller.isSleeping && controller.nextMaintenance == 0)
        print("Passed actual AppDelegate layout stability, adaptive/empty idle, and sleep/wake state checks.")
    }
}
