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
