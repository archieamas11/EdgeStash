import Foundation
import EdgeStashCore

func checkPreferences() {
    let defaults = Preferences()
    precondition(defaults.indicatorWidth >= 16 && defaults.indicatorWidth > 9)
    precondition(defaults.stackByApp && defaults.animate && defaults.openOnHover)
    precondition(defaults.showAppIcon && !defaults.useAppBrandColor)
    precondition(defaults.shortcuts.count == ShortcutAction.allCases.count)
    precondition(defaults.indicatorHeight == 48 && defaults.indicatorCornerRadius == 8 && defaults.indicatorGap == 8)
    let partial = try! JSONDecoder().decode(Preferences.self, from: Data("{\"dismissMode\":\"escape\"}".utf8))
    precondition(partial.dismissMode == .escape && partial.indicatorWidth == defaults.indicatorWidth && partial.openOnHover)
    let clickOnly = try! JSONDecoder().decode(Preferences.self, from: Data("{\"openOnHover\":false}".utf8))
    precondition(!clickOnly.openOnHover)
    let legacy = try! JSONDecoder().decode(Preferences.self, from: Data("{\"indicatorLength\":150}".utf8))
    precondition(legacy.showAppIcon && !legacy.useAppBrandColor)
    precondition(legacy.appIconSize == 32 && !legacy.glassIndicators)
    let encoded = try! JSONEncoder().encode(defaults)
    precondition(!String(decoding: encoded, as: UTF8.self).contains("indicatorLength"))
    var branded = defaults
    branded.useAppBrandColor = true; branded.showAppIcon = false
    branded.openOnHover = false
    branded.indicatorHeight = 80; branded.indicatorCornerRadius = 0; branded.indicatorGap = 12
    branded.indicatorAnchors = ["sample|1|left": 0.75]
    branded.appIconSize = 48; branded.glassIndicators = true
    precondition(try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(branded)) == branded)
    precondition(try! JSONDecoder().decode(Preferences.self, from: encoded) == defaults)
    var invalid = defaults
    invalid.indicatorWidth = .infinity
    invalid.appIconSize = .nan
    invalid.animationDuration = 100; invalid.showDelay = -1; invalid.hideDelay = .nan
    invalid.indicatorColor = "bad"; invalid.appColors = ["valid": "#ff0088", "invalid": "oops"]
    invalid.shortcuts[ShortcutAction.stashRight.rawValue] = defaults.shortcuts[ShortcutAction.stashLeft.rawValue]
    invalid.indicatorHeight = .nan; invalid.indicatorCornerRadius = 100; invalid.indicatorGap = -1
    invalid.indicatorAnchors = ["valid": 1.4, "invalid": .infinity]
    invalid.normalize()
    precondition(invalid.indicatorHeight == 48 && invalid.indicatorCornerRadius == 24 && invalid.indicatorGap == 0)
    precondition(invalid.indicatorAnchors == ["valid": 1])
    precondition(invalid.indicatorWidth == 24)
    invalid.indicatorWidth = 0; invalid.normalize(); precondition(invalid.indicatorWidth == 0)
    precondition(try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(invalid)).indicatorWidth == 0)
    invalid.indicatorWidth = -1; invalid.normalize(); precondition(invalid.indicatorWidth == 0)
    precondition(invalid.appIconSize == 32)
    invalid.appIconSize = 100; invalid.normalize(); precondition(invalid.appIconSize == 64)
    invalid.appIconSize = 0; invalid.normalize(); precondition(invalid.appIconSize == 16)
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
