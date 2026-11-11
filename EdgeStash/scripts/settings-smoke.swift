import SwiftUI
import AppKit
import EdgeStashCore

@MainActor final class SettingsPreviewActions: NSObject {
    let window: NSWindow
    init(window: NSWindow) { self.window = window }
    @objc func appearance(_ sender: NSMenuItem) {
        window.appearance = NSAppearance(named: sender.tag == 0 ? .aqua : .darkAqua)
    }
    @objc func size(_ sender: NSMenuItem) {
        let sizes = [NSSize(width: 820, height: 680), NSSize(width: 740, height: 560), NSSize(width: 960, height: 760)]
        window.setContentSize(sizes[sender.tag])
    }
}

MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var screenRecordingRequests = 0
var accessibilityRequests = 0
var preferenceWrites: [Preferences] = []
let controller = SettingsWindowController(preferences: Preferences(), onChange: { preferenceWrites.append($0) },
    onEnableAccessibility: { accessibilityRequests += 1 }, onRestoreAll: {}, onEnableScreenRecording: { screenRecordingRequests += 1 })
let window = controller.window!
let model = controller.model
window.orderFront(nil)
for pane in SettingsPane.allCases {
    model.pane = pane
    for size in [NSSize(width: 820, height: 680), NSSize(width: 960, height: 760), NSSize(width: 740, height: 560)] {
        window.setContentSize(size)
        window.contentView!.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let actual = window.contentView!.bounds.size
        precondition(actual.width >= size.width - 1 && actual.height >= size.height - 1, "Native Settings must fill each supported window size")
    }
}
precondition(screenRecordingRequests == 0 && accessibilityRequests == 0 && preferenceWrites.isEmpty,
    "Opening and navigating settings must not change preferences or request permissions")
model.onEnableScreenRecording()
precondition(screenRecordingRequests == 1, "Only the explicit Screen Recording action should request capture access")
model.binding(\.indicatorWidth).wrappedValue = 0
precondition(preferenceWrites.last!.indicatorWidth == 0, "The native control binding must preserve zero-thickness support")
@MainActor func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
}
model.pane = .shortcuts
model.startRecording(.stashLeft); model.record(key(0))
precondition(model.recordingError != nil && model.recording == .stashLeft, "An invalid shortcut must leave recording active with an explanation")
model.record(key(124, flags: [.control, .option, .command]))
precondition(model.recordingError?.contains("already assigned") == true, "Duplicate shortcuts must remain rejected")
model.record(key(3, flags: [.control, .option, .command]))
precondition(model.preferences.shortcuts[ShortcutAction.stashLeft.rawValue]?.keyCode == 3 && model.recording == nil,
    "A valid recording must save and leave capture mode")
let recorded = model.preferences.shortcuts
model.startRecording(.stashLeft); model.record(key(53))
precondition(model.preferences.shortcuts == recorded && model.recording == nil, "Escape must cancel without modifying shortcuts")
model.startRecording(.stashLeft); model.record(key(51))
precondition(model.preferences.shortcuts[ShortcutAction.stashLeft.rawValue] == nil, "Delete must clear a shortcut")
model.startRecording(.stashRight); model.pane = .appearance
precondition(model.recording == nil, "Changing settings panes must remove the keyboard recorder")
model.change { $0.shortcuts = Preferences.defaultShortcuts }
let help = HelpPopoverState()
help.hoverIcon(true); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
precondition(help.presented && !help.pinned, "Hovering the info icon must open its popover")
help.hoverIcon(false); help.hoverContent(true); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
precondition(help.presented, "Moving into the popover must keep the explanation readable")
help.hoverContent(false); RunLoop.main.run(until: Date().addingTimeInterval(0.25))
precondition(!help.presented, "Hover help must close after leaving both the icon and popover")
help.click(); help.hoverIcon(false); RunLoop.main.run(until: Date().addingTimeInterval(0.25))
precondition(help.presented && help.pinned, "Click and keyboard activation must pin help until dismissed")
help.presented = false
precondition(!help.pinned, "Native outside-click or Escape dismissal must reset pinned help")
help.hoverIcon(true); help.reset(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
precondition(!help.presented, "Leaving a settings pane must cancel pending hover help")
print("Passed three native settings panes at three sizes, permission actions, preference bindings, shortcut recording/conflicts/cancellation, and hover/click popover lifecycle checks.")

if ProcessInfo.processInfo.environment["EDGESTASH_SETTINGS_PREVIEW"] == "1" {
    model.update(preferences: Preferences(), apps: [("com.apple.finder", "Finder"), ("example.browser", "A browser with a longer application name")])
    model.pane = .stash
    app.setActivationPolicy(.regular)
    let actions = SettingsPreviewActions(window: window)
    let menu = NSMenu()
    let appMenu = NSMenu()
    let quit = NSMenuItem(title: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = app; appMenu.addItem(quit)
    let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
    let preview = NSMenu(title: "Preview")
    for (index, title) in ["Light Appearance", "Dark Appearance"].enumerated() {
        let item = NSMenuItem(title: title, action: #selector(SettingsPreviewActions.appearance(_:)), keyEquivalent: "")
        item.tag = index; item.target = actions; preview.addItem(item)
    }
    preview.addItem(.separator())
    for (index, title) in ["Standard Size", "Compact Size", "Wide Size"].enumerated() {
        let item = NSMenuItem(title: title, action: #selector(SettingsPreviewActions.size(_:)), keyEquivalent: "")
        item.tag = index; item.target = actions; preview.addItem(item)
    }
    let previewItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: ""); previewItem.submenu = preview; menu.addItem(previewItem)
    app.mainMenu = menu
    window.title = "EdgeStash Settings Preview"
    window.setContentSize(NSSize(width: 820, height: 680))
    controller.showWindow(nil)
    withExtendedLifetime(actions) { app.run() }
}

let popoverState = HelpPopoverState()
let host = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
host.isReleasedWhenClosed = false
host.contentViewController = NSHostingController(rootView: HStack {
    Text("Stack windows from the same app")
    InfoButton(title: "Stack windows from the same app", detail: "Groups windows by app, edge, display, and desktop. Click the indicator or use Cycle App Stack to move through its windows. Each app stack shows one window at a time.", state: popoverState)
}.padding())
host.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
let oldWindows = Set(app.windows.map { ObjectIdentifier($0) })
popoverState.hoverIcon(true)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
let popup = app.windows.first { $0.isVisible && !oldWindows.contains(ObjectIdentifier($0)) }
precondition(popup != nil && popoverState.presented, "Hover help must present a real native popover window")
popoverState.reset(); host.close()
print("Passed native hover-triggered popover presentation.")
window.close()

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
let thinBar = IndicatorButton(frame: NSRect(x: 0, y: 0, width: 44, height: 100))
for edge in EdgeStashCore.Edge.allCases {
    thinBar.edge = edge; thinBar.thickness = 1
    thinBar.frame.size = (edge == .left || edge == .right) ? NSSize(width: 44, height: 100) : NSSize(width: 100, height: 44)
    let thickness = (edge == .left || edge == .right) ? thinBar.barFrame.width : thinBar.barFrame.height
    precondition(thickness == 1, "Enabling icons must not expand a one-point bar")
}
for edge in EdgeStashCore.Edge.allCases {
    let bar = edge.tabFrame(screen: CGRect(x: 0, y: 0, width: 800, height: 600), index: 0, count: 1, length: 100, width: 1)
    thinBar.frame = edge.indicatorPanelFrame(bar: bar, showIcon: true, iconSize: 32, iconOffset: 40)
    thinBar.edge = edge; thinBar.iconSize = 32; thinBar.iconOffset = 40
    precondition(thinBar.bounds.contains(thinBar.iconTileFrame), "Offset icons must fit their transparent panel on all edges")
    precondition(thinBar.iconTileFrame.width == 32, "Offset must preserve icon size")
}
for edge in EdgeStashCore.Edge.allCases {
    let bar = edge.tabFrame(screen: CGRect(x: 0, y: 0, width: 800, height: 600), index: 0, count: 1, length: 100, width: 1)
    thinBar.edge = edge; thinBar.iconSize = 32; thinBar.iconOffset = 0
    thinBar.frame = edge.indicatorPanelFrame(bar: bar, showIcon: true, iconSize: 32, iconOffset: -24)
    let original = thinBar.iconTileFrame
    thinBar.iconOffset = -24
    let moved = thinBar.iconTileFrame
    precondition(moved.size == original.size, "Negative offsets must not shrink the icon")
    let movement = (edge == .left || edge == .right) ? moved.midX - original.midX : moved.midY - original.midY
    precondition(abs(movement) == 24, "Negative offsets must move the icon toward its edge")
    precondition(thinBar.barFrame.width == 1 || thinBar.barFrame.height == 1, "Negative offsets must preserve bar thickness")
}
let button = IndicatorButton(title: "", target: nil, action: nil)
button.isBordered = false; button.edge = .right; button.icon = redIcon
indicator.contentView = button
indicator.setFrame(NSRect(x: 100, y: 100, width: 40, height: 400), display: false)
indicator.contentView!.layoutSubtreeIfNeeded()
precondition(button.bounds.height == 400 && button.bounds.width == 40, "A floating indicator must fill its assigned window height")
if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) { button.cacheDisplay(in: button.bounds, to: bitmap) }
for edge in EdgeStashCore.Edge.allCases {
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
@MainActor func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
if #available(macOS 26.0, *) {
    let glass = descendants(button).compactMap { $0 as? NSGlassEffectView }.first!
    precondition(glass.tintColor == nil && !glass.isHidden, "Glass mode must use the native untinted material")
    precondition(glass.frame.minY < 0, "The bottom-edge glass must extend outward to square off its outer corners")
    precondition(glass.superview!.layer!.masksToBounds, "The extended glass must be clipped at the display edge")
    button.usesGlass = false; button.needsLayout = true; button.layoutSubtreeIfNeeded()
    precondition(glass.isHidden, "Returning to colors must remove the glass material")
}
print("Passed four-edge icon sizing, click targeting, and native glass switching checks.")
var dragged = false; var released = false; var moveStarted = false
button.onMoveStarted = { moveStarted = true }
button.onDragChanged = { _ in dragged = true }
button.onDragEnded = { _ in released = true }
@MainActor func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: indicator.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
app.postEvent(mouse(.leftMouseDragged, NSPoint(x: 20, y: 30)), atStart: false)
app.postEvent(mouse(.leftMouseUp, NSPoint(x: 20, y: 30)), atStart: false)
button.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 10)))
precondition(!moveStarted && !dragged && !released, "An ordinary drag must not move a note or hijack normal hover/click behavior")
app.postEvent(mouse(.leftMouseDragged, NSPoint(x: 20, y: 30), .shift), atStart: false)
app.postEvent(mouse(.leftMouseUp, NSPoint(x: 20, y: 30), .shift), atStart: false)
button.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 10), .shift))
precondition(moveStarted && dragged && released && !button.isDragging, "Shift-drag must deliver movement and release while suppressing reveal clicks")
print("Passed native ordinary-drag suppression and Shift-drag gesture delivery.")
indicator.close(); scope.marker.close()
print("Passed icon-color extraction/fallback and independent desktop-marker checks.")

}
