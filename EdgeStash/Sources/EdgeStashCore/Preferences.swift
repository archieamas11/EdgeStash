import Foundation

public enum DismissMode: String, Codable, CaseIterable {
    case pointerLeaves, escape
}

public enum ShortcutAction: String, Codable, CaseIterable {
    case stashLeft, stashRight, stashTop, stashBottom, unstash, restoreAll, cycleStack

    public var title: String {
        switch self {
        case .stashLeft: return "Stash Left"
        case .stashRight: return "Stash Right"
        case .stashTop: return "Stash Up"
        case .stashBottom: return "Stash Down"
        case .unstash: return "Unstash Focused Window"
        case .restoreAll: return "Restore All Windows"
        case .cycleStack: return "Cycle App Stack"
        }
    }
}

public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct Preferences: Codable, Equatable {
    public var enabled = true
    public var stackByApp = true
    public var openOnHover = true
    public var dismissMode: DismissMode = .pointerLeaves
    public var animate = true
    public var animationDuration = 0.22
    public var showDelay = 0.15
    public var hideDelay = 0.35
    public var indicatorWidth = 24.0
    public var fullEdgeIndicators = true
    public var indicatorDragModifier = "shift"
    public var indicatorHeight = 48.0
    public var indicatorCornerRadius = 8.0
    public var indicatorGap = 8.0
    public var indicatorAnchors: [String: Double] = [:]
    public var useAppBrandColor = false
    public var showAppIcon = true
    public var appIconSize = 32.0
    public var appIconOffset = 0.0
    public var glassIndicators = false
    public var indicatorColor = "#00A68A"
    public var appColors: [String: String] = [:]
    public var shortcuts: [String: Shortcut] = defaultShortcuts

    public init() {}

    public static var defaultShortcuts: [String: Shortcut] {
        let modifiers: UInt32 = 256 | 2048 | 4096
        return Dictionary(uniqueKeysWithValues: zip(ShortcutAction.allCases, [123, 124, 126, 125, 32, 32, 38] as [UInt32]).map {
            ($0.0.rawValue, Shortcut(keyCode: $0.1, modifiers: modifiers | ($0.0 == .restoreAll ? 512 : 0)))
        })
    }

    enum CodingKeys: String, CodingKey {
        case enabled, stackByApp, openOnHover, dismissMode, animate, animationDuration, showDelay, hideDelay
        case indicatorHeight, indicatorCornerRadius, indicatorGap, indicatorAnchors
        case fullEdgeIndicators, indicatorDragModifier
        case indicatorWidth, useAppBrandColor, showAppIcon, appIconSize, appIconOffset, glassIndicators, indicatorColor, appColors, shortcuts
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        stackByApp = try values.decodeIfPresent(Bool.self, forKey: .stackByApp) ?? stackByApp
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? openOnHover
        if let raw = try values.decodeIfPresent(String.self, forKey: .dismissMode), let mode = DismissMode(rawValue: raw) { dismissMode = mode }
        animate = try values.decodeIfPresent(Bool.self, forKey: .animate) ?? animate
        animationDuration = try values.decodeIfPresent(Double.self, forKey: .animationDuration) ?? animationDuration
        showDelay = try values.decodeIfPresent(Double.self, forKey: .showDelay) ?? showDelay
        hideDelay = try values.decodeIfPresent(Double.self, forKey: .hideDelay) ?? hideDelay
        indicatorWidth = try values.decodeIfPresent(Double.self, forKey: .indicatorWidth) ?? indicatorWidth
        fullEdgeIndicators = try values.decodeIfPresent(Bool.self, forKey: .fullEdgeIndicators) ?? true
        indicatorDragModifier = try values.decodeIfPresent(String.self, forKey: .indicatorDragModifier) ?? "shift"
        indicatorHeight = try values.decodeIfPresent(Double.self, forKey: .indicatorHeight) ?? indicatorHeight
        indicatorCornerRadius = try values.decodeIfPresent(Double.self, forKey: .indicatorCornerRadius) ?? indicatorCornerRadius
        indicatorGap = try values.decodeIfPresent(Double.self, forKey: .indicatorGap) ?? indicatorGap
        indicatorAnchors = try values.decodeIfPresent([String: Double].self, forKey: .indicatorAnchors) ?? indicatorAnchors
        useAppBrandColor = try values.decodeIfPresent(Bool.self, forKey: .useAppBrandColor) ?? useAppBrandColor
        showAppIcon = try values.decodeIfPresent(Bool.self, forKey: .showAppIcon) ?? showAppIcon
        appIconSize = try values.decodeIfPresent(Double.self, forKey: .appIconSize) ?? appIconSize
        appIconOffset = try values.decodeIfPresent(Double.self, forKey: .appIconOffset) ?? appIconOffset
        glassIndicators = try values.decodeIfPresent(Bool.self, forKey: .glassIndicators) ?? glassIndicators
        indicatorColor = try values.decodeIfPresent(String.self, forKey: .indicatorColor) ?? indicatorColor
        appColors = try values.decodeIfPresent([String: String].self, forKey: .appColors) ?? appColors
        shortcuts = try values.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) ?? shortcuts
        normalize()
    }

    public mutating func normalize() {
        animationDuration = bounded(animationDuration, 0.1...0.6, fallback: 0.22)
        showDelay = bounded(showDelay, 0...1, fallback: 0.15)
        hideDelay = bounded(hideDelay, 0...2, fallback: 0.35)
        indicatorWidth = bounded(indicatorWidth, 0...48, fallback: 24)
        if !["shift", "option", "control", "command"].contains(indicatorDragModifier) { indicatorDragModifier = "shift" }
        indicatorHeight = bounded(indicatorHeight, 24...320, fallback: 48)
        indicatorCornerRadius = bounded(indicatorCornerRadius, 0...24, fallback: 8)
        indicatorGap = bounded(indicatorGap, 0...48, fallback: 8)
        indicatorAnchors = indicatorAnchors.filter { !$0.key.isEmpty && $0.value.isFinite }.mapValues { min(max($0, 0), 1) }
        appIconOffset = bounded(appIconOffset, -64...64, fallback: 0)
        appIconSize = bounded(appIconSize, 16...64, fallback: 32)
        indicatorColor = validHexColor(indicatorColor) ? indicatorColor.uppercased() : "#00A68A"
        appColors = appColors.filter { !$0.key.isEmpty && validHexColor($0.value) }.mapValues { $0.uppercased() }
        var valid: [String: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action.rawValue], shortcut.keyCode <= 127, shortcut.keyCode != 53,
                  shortcut.modifiers & (256 | 2048 | 4096) != 0,
                  shortcut.modifiers & ~(256 | 512 | 2048 | 4096) == 0,
                  !valid.values.contains(shortcut) else { continue }
            valid[action.rawValue] = shortcut
        }
        shortcuts = valid
    }
}

private func bounded(_ value: Double, _ limits: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(max(value, limits.lowerBound), limits.upperBound) : fallback
}

public func validHexColor(_ value: String) -> Bool {
    value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
}

public func shortcutValidationError(_ shortcut: Shortcut, action: ShortcutAction, in preferences: Preferences) -> String? {
    if shortcut.keyCode > 127 { return "This key cannot be used as a global shortcut." }
    if shortcut.keyCode == 53 { return "Escape is reserved for hiding a revealed stash or canceling recording." }
    if shortcut.modifiers & (256 | 2048 | 4096) == 0 { return "Include Control, Option, or Command in the shortcut." }
    if shortcut.modifiers & ~(256 | 512 | 2048 | 4096) != 0 { return "Use only Control, Option, Command, and Shift modifiers." }
    if let other = ShortcutAction.allCases.first(where: { $0 != action && preferences.shortcuts[$0.rawValue] == shortcut }) {
        return "That shortcut is already assigned to \(other.title)."
    }
    return nil
}
