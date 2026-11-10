import Foundation
import EdgeStashCore

func checkPreferences() {
    let defaults = Preferences()
    precondition(defaults.indicatorWidth >= 16 && defaults.indicatorWidth > 9)
    precondition(defaults.stackByApp && defaults.animate)
    precondition(defaults.shortcuts.count == ShortcutAction.allCases.count)
    let partial = try! JSONDecoder().decode(Preferences.self, from: Data("{\"dismissMode\":\"escape\"}".utf8))
    precondition(partial.dismissMode == .escape && partial.indicatorWidth == defaults.indicatorWidth)
    let encoded = try! JSONEncoder().encode(defaults)
    precondition(try! JSONDecoder().decode(Preferences.self, from: encoded) == defaults)
    var invalid = defaults
    invalid.indicatorWidth = .infinity; invalid.indicatorLength = -4
    invalid.animationDuration = 100; invalid.showDelay = -1; invalid.hideDelay = .nan
    invalid.indicatorColor = "bad"; invalid.appColors = ["valid": "#ff0088", "invalid": "oops"]
    invalid.shortcuts[ShortcutAction.stashRight.rawValue] = defaults.shortcuts[ShortcutAction.stashLeft.rawValue]
    invalid.normalize()
    precondition(invalid.indicatorWidth == 24 && invalid.indicatorLength == 48)
    precondition(invalid.animationDuration == 0.6 && invalid.showDelay == 0 && invalid.hideDelay == 0.35)
    precondition(invalid.indicatorColor == defaults.indicatorColor && invalid.appColors == ["valid": "#FF0088"])
    precondition(invalid.shortcuts[ShortcutAction.stashRight.rawValue] == nil)
    precondition(shortcutValidationError(Shortcut(keyCode: 0, modifiers: 0), action: .unstash, in: defaults) != nil)
    precondition(shortcutValidationError(Shortcut(keyCode: 53, modifiers: 256), action: .unstash, in: defaults) != nil)
    precondition(shortcutValidationError(defaults.shortcuts[ShortcutAction.stashLeft.rawValue]!, action: .unstash, in: defaults) != nil)
    precondition(shortcutValidationError(Shortcut(keyCode: 0, modifiers: 256 | 2048), action: .unstash, in: defaults) == nil)
    var cleared = defaults
    cleared.shortcuts = [:]
    cleared.normalize()
    precondition(cleared.shortcuts.isEmpty)
    print("Passed preferences checks: defaults, partial/round-trip persistence, bounds, colors, shortcut conflicts and clearing.")
}
