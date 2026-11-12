import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import EdgeStashCore

private final class IndicatorPreview: NSView {
    var preferences = Preferences() { didSet { needsLayout = true; needsDisplay = true } }
    private let sample = IndicatorButton(title: "", target: nil, action: nil)
    private let sampleIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sample.isBordered = false
        addSubview(sample)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let bar = Edge.left.tabFrame(screen: bounds.insetBy(dx: 6, dy: 6), index: 0, count: 1,
            length: preferences.fullEdgeIndicators ? bounds.height - 12 : preferences.indicatorHeight, width: preferences.indicatorWidth)
        sample.frame = Edge.left.indicatorPanelFrame(bar: bar, showIcon: preferences.showAppIcon, iconSize: preferences.appIconSize, iconOffset: preferences.appIconOffset)
        sample.edge = .left; sample.thickness = preferences.indicatorWidth
        sample.icon = sampleIcon; sample.showIcon = preferences.showAppIcon
        sample.iconOffset = preferences.appIconOffset; sample.iconSize = preferences.appIconSize; sample.usesGlass = preferences.glassIndicators
        sample.cornerRadius = preferences.indicatorCornerRadius
        sample.tint = preferences.useAppBrandColor ? dominantAppIconColor(sampleIcon) ?? colorFromHex(preferences.indicatorColor) : colorFromHex(preferences.indicatorColor)
        sample.needsLayout = true; sample.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = "Your windows, within reach"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: max(70, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

func colorFromHex(_ value: String) -> NSColor {
    let number = UInt32(value.dropFirst(), radix: 16) ?? 0x00A68A
    return NSColor(calibratedRed: CGFloat((number >> 16) & 255) / 255,
                   green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
}

private func hexFromColor(_ value: NSColor) -> String {
    guard let rgb = value.usingColorSpace(.sRGB) else { return "#00A68A" }
    return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                  Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
}

private func shortcutTitle(_ shortcut: Shortcut?) -> String {
    guard let shortcut else { return "Record Shortcut" }
    var title = ""
    if shortcut.modifiers & UInt32(controlKey) != 0 { title += "⌃" }
    if shortcut.modifiers & UInt32(optionKey) != 0 { title += "⌥" }
    if shortcut.modifiers & UInt32(shiftKey) != 0 { title += "⇧" }
    if shortcut.modifiers & UInt32(cmdKey) != 0 { title += "⌘" }
    let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",123:"←",124:"→",125:"↓",126:"↑"]
    return title + (keys[shortcut.keyCode] ?? "Key \(shortcut.keyCode)")
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case stash, shortcuts, appearance
    var id: Self { self }
    var title: String { switch self { case .stash: return "Stash"; case .shortcuts: return "Shortcuts"; case .appearance: return "Appearance" } }
    var symbol: String { switch self { case .stash: return "rectangle.trailinghalf.inset.filled"; case .shortcuts: return "command"; case .appearance: return "paintpalette" } }
}

struct SettingsApp: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor final class SettingsModel: ObservableObject {
    @Published var preferences: Preferences
    @Published var apps: [SettingsApp] = []
    @Published var pane: SettingsPane? = .stash { didSet { if pane != oldValue { stopRecording() } } }
    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var recordingError: String?
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var screenRecordingAllowed = false
    weak var window: NSWindow?
    let onEnableAccessibility: () -> Void
    let onEnableScreenRecording: () -> Void
    let onRestoreAll: () -> Void
    private let onChange: (Preferences) -> Void
    private var recorderMonitor: Any?

    init(preferences: Preferences, onChange: @escaping (Preferences) -> Void,
         onEnableAccessibility: @escaping () -> Void, onRestoreAll: @escaping () -> Void,
         onEnableScreenRecording: @escaping () -> Void) {
        self.preferences = preferences; self.onChange = onChange
        self.onEnableAccessibility = onEnableAccessibility; self.onRestoreAll = onRestoreAll
        self.onEnableScreenRecording = onEnableScreenRecording
        refreshAccess()
    }

    var supportsImageSlides: Bool { if #available(macOS 14, *) { return true }; return false }

    func refreshAccess() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = supportsImageSlides && CGPreflightScreenCaptureAccess()
    }

    func update(preferences: Preferences, apps: [(id: String, name: String)]) {
        if self.preferences != preferences { self.preferences = preferences }
        let values = apps.map { SettingsApp(id: $0.id, name: $0.name) }
        if self.apps != values { self.apps = values }
    }

    func change(_ edit: (inout Preferences) -> Void) {
        var next = preferences; edit(&next); next.normalize()
        guard next != preferences else { return }
        preferences = next; onChange(next)
    }

    func binding<Value>(_ path: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: path] }, set: { value in self.change { $0[keyPath: path] = value } })
    }

    func startRecording(_ action: ShortcutAction) {
        stopRecording(); recording = action
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true, self.recording != nil else { return false }
                self.record(event); return true
            }
            return consumed ? nil : event
        }
    }

    func record(_ event: NSEvent) {
        guard let action = recording else { return }
        if event.keyCode == 53 { stopRecording(); return }
        if event.keyCode == 51 || event.keyCode == 117 { change { $0.shortcuts.removeValue(forKey: action.rawValue) }; stopRecording(); return }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if let error = shortcutValidationError(shortcut, action: action, in: preferences) { recordingError = error; return }
        change { $0.shortcuts[action.rawValue] = shortcut }; stopRecording()
    }

    func stopRecording() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        recorderMonitor = nil; recording = nil; recordingError = nil
    }

    deinit { if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) } }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(preferences: Preferences, onChange: @escaping (Preferences) -> Void,
         onEnableAccessibility: @escaping () -> Void, onRestoreAll: @escaping () -> Void,
         onEnableScreenRecording: @escaping () -> Void = {}) {
        model = SettingsModel(preferences: preferences, onChange: onChange, onEnableAccessibility: onEnableAccessibility,
                              onRestoreAll: onRestoreAll, onEnableScreenRecording: onEnableScreenRecording)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "EdgeStash Settings"
        window.identifier = NSUserInterfaceItemIdentifier("EdgeStashSettings")
        window.contentMinSize = NSSize(width: 740, height: 560)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        super.init(window: window)
        model.window = window; window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        window.setFrameAutosaveName("EdgeStashSettings")
        if !window.setFrameUsingName("EdgeStashSettings") { window.center() }
    }
    required init?(coder: NSCoder) { nil }
    func update(preferences: Preferences, apps: [(id: String, name: String)]) { model.update(preferences: preferences, apps: apps) }
    override func showWindow(_ sender: Any?) {
        model.refreshAccess(); super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender); NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { model.refreshAccess() }
    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }
    func windowWillClose(_ notification: Notification) { model.stopRecording() }
}

@MainActor final class HelpPopoverState: ObservableObject {
    @Published var presented = false { didSet { if !presented { pinned = false } } }
    private(set) var pinned = false
    private var iconHovered = false
    private var contentHovered = false
    private var pending: DispatchWorkItem?

    func hoverIcon(_ inside: Bool) { iconHovered = inside; schedule() }
    func hoverContent(_ inside: Bool) { contentHovered = inside; schedule() }
    func click() {
        pending?.cancel()
        if presented && pinned { reset() } else { pinned = true; presented = true }
    }
    private func schedule() {
        pending?.cancel()
        let inside = iconHovered || contentHovered
        guard inside || !pinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.presented = self.iconHovered || self.contentHovered || self.pinned
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.2), execute: work)
    }
    func reset() { pending?.cancel(); pending = nil; pinned = false; iconHovered = false; contentHovered = false; presented = false }
    deinit { pending?.cancel() }
}

struct InfoButton: View {
    let title: String
    let detail: String
    @StateObject private var state: HelpPopoverState
    init(title: String, detail: String, state: HelpPopoverState? = nil) {
        self.title = title; self.detail = detail
        _state = StateObject(wrappedValue: state ?? HelpPopoverState())
    }
    var body: some View {
        Button { state.click() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More about \(title)")
        .help("More about \(title)")
        .onHover { state.hoverIcon($0) }
        .popover(isPresented: $state.presented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 300, alignment: .leading)
            .onHover { state.hoverContent($0) }
        }
        .onDisappear { state.reset() }
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }
    var body: some View { HStack(spacing: 3) { Text(title); InfoButton(title: title, detail: detail) } }
}

private struct SettingRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12) {
            SettingLabel(title, detail)
            Spacer(minLength: 12)
            content()
        }
        .accessibilityElement(children: .contain)
    }
}

private struct IndicatorPreviewView: NSViewRepresentable {
    let preferences: Preferences
    func makeNSView(context: Context) -> IndicatorPreview { IndicatorPreview() }
    func updateNSView(_ view: IndicatorPreview, context: Context) { view.preferences = preferences }
}

private struct AccessStatus: View {
    let allowed: Bool
    let required: Bool
    var body: some View {
        Label(allowed ? "Allowed" : (required ? "Required" : "Not enabled"), systemImage: allowed ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(allowed ? Color.secondary : (required ? Color.orange : Color.secondary))
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    private var versionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Version \($0)" } ?? "A place for every window."
    }
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
                    .padding(.vertical, 3).accessibilityLabel("\(pane.title) settings")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EdgeStash").font(.callout.weight(.medium))
                    Text(versionText)
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            Group {
                switch model.pane ?? .stash {
                case .stash: stashPage
                case .shortcuts: shortcutsPage
                case .appearance: appearancePage
                }
            }
            .navigationTitle((model.pane ?? .stash).title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, minHeight: 560)
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<Preferences, Bool>, _ detail: String, enabled: Bool = true) -> some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: model.binding(path)).labelsHidden().toggleStyle(.switch).disabled(!enabled)
        }
    }

    private func measurement(_ title: String, _ path: WritableKeyPath<Preferences, Double>, range: ClosedRange<Double>, unit: String, detail: String, enabled: Bool = true) -> some View {
        SettingRow(title: title, detail: detail) {
            HStack(spacing: 10) {
                Slider(value: model.binding(path), in: range).frame(width: 135)
                    .accessibilityLabel(title).accessibilityValue(formatted(model.preferences[keyPath: path], unit: unit))
                TextField(title, value: model.binding(path), format: .number.precision(.fractionLength(unit == "pt" ? 0 : 2)))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64).accessibilityLabel("\(title) value")
                Text(unit).foregroundStyle(.secondary).frame(width: 16)
            }.disabled(!enabled)
        }
    }

    private func formatted(_ value: Double, unit: String) -> String {
        unit == "pt" ? "\(Int(value.rounded())) pt" : String(format: "%.2f s", value)
    }

    private var stashPage: some View {
        Form {
            Section("General") {
                toggle("Enable Stash", \.enabled, "Hide windows at an edge of your current desktop and reveal them without rearranging your workspace. Turning this off restores every stashed window.")
                toggle("Stack windows from the same app", \.stackByApp, "Groups windows by app, edge, display, and desktop. Click the indicator or use Cycle App Stack to move through its windows. Each app stack shows one window at a time.")
            }
            Section("Reveal & dismiss") {
                toggle("Open on hover", \.openOnHover, "Reveal a window by hovering over its indicator. Turn this off for click-only opening. Clicking also cycles an app’s stack; Dragging with your selected modifier moves the indicator.")
                SettingRow(title: "Hide revealed windows", detail: "Cursor mode hides a window after the pointer leaves its area and the stash indicators. Hovering another indicator keeps it open. Escape mode keeps it above ordinary app windows until you press Escape; Escape never closes the document or quits the app.") {
                    Picker("Hide revealed windows", selection: model.binding(\.dismissMode)) {
                        Text("When the cursor leaves").tag(DismissMode.pointerLeaves)
                        Text("Only when I press Escape").tag(DismissMode.escape)
                    }.labelsHidden().fixedSize()
                }
                measurement("Reveal delay", \.showDelay, range: 0...1, unit: "s", detail: "How long to hover before a stash opens. Clicking opens it immediately.", enabled: model.preferences.openOnHover)
                measurement("Hide delay", \.hideDelay, range: 0...2, unit: "s", detail: "How long to wait after the pointer leaves a revealed window. This does not apply in Escape mode.", enabled: model.preferences.dismissMode != .escape)
            }
            Section("Motion") {
                toggle("Slide windows and indicators", \.animate, "Animate window movement and returning indicators. Windows align with their indicator inside usable screen bounds. Resizing remembers the new size; moving a revealed window unstashes it. Motion respects macOS Reduce Motion.")
                measurement("Slide duration", \.animationDuration, range: 0.1...0.6, unit: "s", detail: "The duration of each opening or hiding slide. macOS Reduce Motion takes priority over this setting.", enabled: model.preferences.animate)
            }
            Section {
                SettingRow(title: "Control app windows", detail: "Accessibility access allows EdgeStash to move, resize, focus, and restore individual windows in other apps. You can review or revoke access in System Settings.") {
                    HStack(spacing: 10) { AccessStatus(allowed: model.accessibilityAllowed, required: true); Button("Accessibility…", action: model.onEnableAccessibility) }
                }
                SettingRow(title: "Top-edge animation", detail: "macOS can prevent a real window from sliding above the menu bar. With Screen Recording access on macOS 14 or later, EdgeStash animates a temporary image of that one window and then hands control back. No files are saved, no audio is captured, and nothing is uploaded. Without access, top windows open directly.") {
                    HStack(spacing: 10) { AccessStatus(allowed: model.screenRecordingAllowed, required: false); Button("Screen Recording…", action: model.onEnableScreenRecording).disabled(!model.supportsImageSlides) }
                }
                SettingRow(title: "Restore stashed windows", detail: "Bring every stashed window back to its pre-stash position with its latest size. If a window refuses restoration, its recovery entry is kept.") { Button("Restore All", action: model.onRestoreAll) }
            } header: { Text("Access & recovery") } footer: {
                Text(model.supportsImageSlides ? "Screen Recording is optional. Temporary window images stay on this Mac and are discarded after each transition." : "Top-edge image animation requires macOS 14 or later. Stashing still works without it.")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(model.recording == action ? "Press keys…" : shortcutTitle(model.preferences.shortcuts[action.rawValue])) { model.startRecording(action) }
                    .frame(width: 155).accessibilityLabel("Record shortcut for \(action.title)")
                Button {
                    model.stopRecording(); model.change { $0.shortcuts.removeValue(forKey: action.rawValue) }
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Clear shortcut")
                .accessibilityLabel("Clear shortcut for \(action.title)")
                .disabled(model.preferences.shortcuts[action.rawValue] == nil)
            }
        } label: { Text(action.title) }
    }

    private var shortcutsPage: some View {
        Form {
            Section("Stash a window") {
                ForEach(Array(ShortcutAction.allCases.prefix(4)), id: \.rawValue) { shortcutRow($0) }
            }
            Section("Manage stashes") {
                ForEach(Array(ShortcutAction.allCases.suffix(3)), id: \.rawValue) { shortcutRow($0) }
            }
            Section {
                if let error = model.recordingError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Shortcut error: \(error)")
                } else if let recording = model.recording {
                    Text("Recording \(recording.title). Escape cancels; Delete clears.").foregroundStyle(.secondary)
                } else {
                    Text("Click a shortcut, then press a key combination with Control, Option, or Command.").foregroundStyle(.secondary)
                }
                SettingRow(title: "Default shortcuts", detail: "Restore the original key combinations for all stash commands. Shortcuts work globally. Clearing a shortcut turns that command’s keyboard trigger off. Escape is reserved for hiding stashes and canceling recording.") { Button("Restore Defaults") { model.stopRecording(); model.change { $0.shortcuts = Preferences.defaultShortcuts } } }
            }
        }
        .formStyle(.grouped)
    }

    private var appearancePage: some View {
        VStack(spacing: 0) {
            GroupBox {
                IndicatorPreviewView(preferences: model.preferences).frame(height: 95)
            } label: { Text("Indicator preview").font(.callout).foregroundStyle(.secondary) }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            Form {
                Section("Size & shape") {
                    measurement("Thickness", \.indicatorWidth, range: 0...48, unit: "pt", detail: "Set thickness to 0 for an icon-only indicator. With icons hidden too, an invisible one-point edge target still reveals the stash.")
                    toggle("Use full edge", \.fullEdgeIndicators, "Fill the available edge and divide it equally between app indicators. Drag with the selected modifier to swap slots. Turn off to choose a custom height and magnetic positions. Top and bottom use the safe width beside the notch or Dock.")
                    measurement("Height", \.indicatorHeight, range: 24...320, unit: "pt", detail: "The length of each indicator along its edge. Top and bottom indicators use this size horizontally. Notes shrink only when needed to fit the available edge space.", enabled: !model.preferences.fullEdgeIndicators)
                    measurement("Corner radius", \.indicatorCornerRadius, range: 0...24, unit: "pt", detail: "Round the two inward corners. The outside of the indicator remains square against the display edge.")
                    measurement("Gap", \.indicatorGap, range: 0...48, unit: "pt", detail: "Space between indicators in both full-edge and custom-height modes. Notes are packed to prevent overlap; crowded edges reduce height or gap to fit.")
                    SettingRow(title: "Indicator positions", detail: "Hold the selected drag modifier to reposition an indicator. Full-edge mode swaps slots; custom height uses magnetic placement with gaps. Top notes avoid the notch, and bottom notes sit beside the Dock. Reset restores automatic placement.") { Button("Reset Positions") { model.change { $0.indicatorAnchors = [:] } } }
                }
                Section("Moving indicators") {
                    SettingRow(title: "Drag modifier", detail: "Hold this key and drag an indicator. Full-edge mode swaps positions on release; custom-height mode uses magnetic, non-overlapping placement. Holding the key pauses hover opening.") {
                        Picker("Drag modifier", selection: model.binding(\.indicatorDragModifier)) {
                            Text("Shift").tag("shift"); Text("Option").tag("option")
                            Text("Control").tag("control"); Text("Command").tag("command")
                        }.labelsHidden()
                    }
                }
                Section("App icons") {
                    toggle("Show app icon", \.showAppIcon, "Show the app icon inside its indicator. Open windows hide their indicator until they return to the stash.")
                    measurement("App icon size", \.appIconSize, range: 16...64, unit: "pt", detail: "The icon is independent of bar thickness and shrinks to fit the selected indicator height.", enabled: model.preferences.showAppIcon)
                    measurement("App icon offset", \.appIconOffset, range: -64...64, unit: "pt", detail: "Move the icon independently of bar thickness. Negative values move toward the display edge; positive values move inward. Parts beyond the screen edge are clipped.", enabled: model.preferences.showAppIcon)
                }
                Section("Material") {
                    toggle("Liquid Glass indicators", \.glassIndicators, "Use untinted native Liquid Glass on macOS 26 or later, with a frosted-glass fallback on macOS 13–15. Turn it off to use indicator colors. Your color choices are retained.")
                }
                colorSection
            }
            .formStyle(.grouped)
        }
    }

    private var colorSection: some View {
        Section {
            toggle("Use app brand color", \.useAppBrandColor, "Estimate a brand color from the app icon’s dominant saturated color. Neutral icons use the default color. Per-app overrides take priority.", enabled: !model.preferences.glassIndicators)
            SettingRow(title: "Default indicator color", detail: "Used when automatic brand color is off or the app has a neutral icon. Per-app overrides take priority.") { ColorPicker("Default indicator color", selection: colorBinding(nil), supportsOpacity: false).labelsHidden().disabled(model.preferences.glassIndicators) }
            ForEach(model.apps) { app in
                LabeledContent {
                    HStack(spacing: 10) {
                        ColorPicker("Indicator color for \(app.name)", selection: colorBinding(app.id), supportsOpacity: false).labelsHidden()
                        Button("Reset") { model.change { $0.appColors.removeValue(forKey: app.id) } }
                            .disabled(model.preferences.appColors[app.id] == nil).accessibilityLabel("Reset indicator color for \(app.name)")
                    }
                    .disabled(model.preferences.glassIndicators)
                } label: { Text(app.name) }
            }
        } header: { Text("Colors") } footer: {
            if model.preferences.glassIndicators { Text("Turn off Liquid Glass indicators to edit colors. Your choices are kept.") }
            else if model.apps.isEmpty { Text("Stash an app to set its individual indicator color.") }
            else { Text("Reset an app color to use the automatic color again.") }
        }
    }

    private func colorBinding(_ appID: String?) -> Binding<Color> {
        Binding(get: {
            Color(nsColor: colorFromHex(appID.flatMap { model.preferences.appColors[$0] } ?? model.preferences.indicatorColor))
        }, set: { color in
            let value = hexFromColor(NSColor(color))
            model.change { if let appID { $0.appColors[appID] = value } else { $0.indicatorColor = value } }
        })
    }
}
