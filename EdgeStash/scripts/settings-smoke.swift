import AppKit
import EdgeStashCore

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = SettingsWindowController(preferences: Preferences(), onChange: { _ in },
    onEnableAccessibility: {}, onRestoreAll: {})
let window = controller.window!
for size in [NSSize(width: 840, height: 680), NSSize(width: 960, height: 760), NSSize(width: 760, height: 580)] {
    window.setContentSize(size)
    window.contentView!.layoutSubtreeIfNeeded()
    let actual = window.contentView!.bounds.size
    precondition(abs(actual.width - size.width) < 1 && abs(actual.height - size.height) < 1,
                 "Settings content must fill its window; separators must not collapse its height")
    let scroll = window.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
    precondition(scroll.frame.height > 500 && scroll.frame.width > 500, "Settings controls must have a usable viewport")
}
print("Passed native settings construction and 3 window-size layout checks.")

let redIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
    NSColor.red.setFill(); rect.fill(); return true
}
let dominant = dominantAppIconColor(redIcon)!.usingColorSpace(.sRGB)!
precondition(dominant.redComponent > 0.95 && dominant.greenComponent < 0.05)
let grayIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
    NSColor.gray.setFill(); rect.fill(); return true
}
precondition(dominantAppIconColor(grayIcon) == nil, "Neutral icons should use the configured default")
let whiteWithBlue = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
    NSColor.white.setFill(); rect.fill()
    NSColor.blue.setFill(); NSRect(x: 10, y: 10, width: 12, height: 12).fill(); return true
}
precondition(dominantAppIconColor(whiteWithBlue)!.usingColorSpace(.sRGB)!.blueComponent > 0.95)
precondition(dominantAppIconColor(nil) == nil)
app.setActivationPolicy(.accessory)
let scope = StashScope(screen: NSRect(x: 100, y: 100, width: 600, height: 400))
precondition(scope.marker.isVisible, "The desktop marker must remain ordered")
let deadline = Date().addingTimeInterval(1)
while !scope.isActive && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(scope.isActive, "A newly ordered desktop marker must belong to the current Space")
let membership = scope.isActive
let indicator = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 40, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
indicator.orderOut(nil)
precondition(scope.marker.isVisible && scope.isActive == membership, "Hiding an indicator must not hide its desktop marker")
let button = IndicatorButton(title: "", target: nil, action: nil)
button.isBordered = false; button.edge = .right; button.icon = redIcon
indicator.contentView = button
indicator.setFrame(NSRect(x: 100, y: 100, width: 40, height: 400), display: false)
indicator.contentView!.layoutSubtreeIfNeeded()
precondition(button.bounds.height == 400 && button.bounds.width == 40, "A floating indicator must fill its assigned window height")
if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) { button.cacheDisplay(in: button.bounds, to: bitmap) }
for edge in Edge.allCases {
    for size in [16.0, 32, 64] {
        let bar = edge.tabFrame(screen: CGRect(x: 0, y: 0, width: 800, height: 600), index: 0, count: 1, length: 300, width: 24)
        let frame = edge.indicatorPanelFrame(bar: bar, showIcon: true, iconSize: size)
        indicator.setFrame(frame, display: false)
        button.edge = edge; button.iconSize = size; button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        precondition(button.bounds.contains(button.iconTileFrame), "All icon sizes must fit their panel on every edge")
        precondition(button.iconTileFrame.width == size, "App icon size must be independent of bar thickness")
        precondition(button.hitTest(NSPoint(x: button.bounds.midX, y: button.bounds.midY)) === button, "Decorative layers must not intercept indicator clicks")
    }
}
button.usesGlass = true; button.needsLayout = true; button.layoutSubtreeIfNeeded()
func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
if #available(macOS 26.0, *) {
    let glass = descendants(button).compactMap { $0 as? NSGlassEffectView }.first!
    precondition(glass.tintColor == nil && !glass.isHidden, "Glass mode must use the native untinted material")
    precondition(glass.frame.minY < 0, "The bottom-edge glass must extend outward to square off its outer corners")
    precondition(glass.superview!.layer!.masksToBounds, "The extended glass must be clipped at the display edge")
    button.usesGlass = false; button.needsLayout = true; button.layoutSubtreeIfNeeded()
    precondition(glass.isHidden, "Returning to colors must remove the glass material")
}
print("Passed four-edge icon sizing, click targeting, and native glass switching checks.")
var dragged = false; var released = false
button.onDragChanged = { _ in dragged = true }
button.onDragEnded = { _ in released = true }
func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: indicator.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
app.postEvent(mouse(.leftMouseDragged, NSPoint(x: 20, y: 30)), atStart: false)
app.postEvent(mouse(.leftMouseUp, NSPoint(x: 20, y: 30)), atStart: false)
button.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 10)))
precondition(dragged && released && !button.isDragging, "A native sticky-note drag must deliver movement and release instead of consuming the gesture")
print("Passed native mouse-down/drag/up gesture delivery.")
indicator.close(); scope.marker.close()
print("Passed icon-color extraction/fallback and independent desktop-marker checks.")
