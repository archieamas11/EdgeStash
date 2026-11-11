import AppKit
import Carbon
import EdgeStashCore

private let stashTint = NSColor(calibratedRed: 0, green: 0.55, blue: 0.45, alpha: 1)

private final class SettingsAction: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func invoke(_ sender: NSControl) { run(sender) }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
            length: preferences.indicatorHeight, width: preferences.indicatorWidth)
        sample.frame = Edge.left.indicatorPanelFrame(bar: bar, showIcon: preferences.showAppIcon, iconSize: preferences.appIconSize)
        sample.edge = .left; sample.thickness = preferences.indicatorWidth
        sample.icon = sampleIcon; sample.showIcon = preferences.showAppIcon
        sample.iconSize = preferences.appIconSize; sample.usesGlass = preferences.glassIndicators
        sample.cornerRadius = preferences.indicatorCornerRadius
        sample.tint = preferences.useAppBrandColor ? dominantAppIconColor(sampleIcon) ?? colorFromHex(preferences.indicatorColor) : colorFromHex(preferences.indicatorColor)
        sample.needsLayout = true; sample.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).stroke()
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

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var preferences: Preferences
    private var apps: [(id: String, name: String)] = []
    private let onChange: (Preferences) -> Void
    private let onEnableAccessibility: () -> Void
    private let onRestoreAll: () -> Void
    private var page = 0
    private var actions: [SettingsAction] = []
    private var sidebarButtons: [NSButton] = []
    private let column = NSStackView()
    private weak var scrollView: NSScrollView?
    private var recording: ShortcutAction?
    private var recorderButtons: [ShortcutAction: NSButton] = [:]
    private var recorderMonitor: Any?
    private let recordingMessage = NSTextField(wrappingLabelWithString: "")
    private weak var preview: IndicatorPreview?

    init(preferences: Preferences, onChange: @escaping (Preferences) -> Void,
         onEnableAccessibility: @escaping () -> Void, onRestoreAll: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        self.onEnableAccessibility = onEnableAccessibility
        self.onRestoreAll = onRestoreAll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "EdgeStash Settings"
        window.identifier = NSUserInterfaceItemIdentifier("EdgeStashSettings")
        window.minSize = NSSize(width: 760, height: 580)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildWindow()
        render()
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    deinit { if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) } }

    func update(preferences: Preferences, apps: [(id: String, name: String)]) {
        let changed = self.preferences != preferences || self.apps.map(\.id) != apps.map(\.id) || self.apps.map(\.name) != apps.map(\.name)
        self.preferences = preferences
        self.apps = apps
        if changed { render() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    private func buildWindow() {
        guard let root = window?.contentView else { return }
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        let scroll = NSScrollView()
        scrollView = scroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        [sidebar, divider, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 192),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let navigation = NSStackView()
        navigation.orientation = .vertical; navigation.alignment = .leading; navigation.spacing = 7
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        NSLayoutConstraint.activate([navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 25),
                                     navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
                                     navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14)])
        let brand = label("EdgeStash", size: 17, weight: .semibold)
        navigation.addArrangedSubview(brand)
        navigation.setCustomSpacing(24, after: brand)
        for (index, item) in [("Stash", "rectangle.trailinghalf.inset.filled"), ("Shortcuts", "command"), ("Appearance", "paintpalette")].enumerated() {
            let button = NSButton(title: "  \(item.0)", target: self, action: #selector(selectPage(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.font = .systemFont(ofSize: 14, weight: .medium)
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            button.setAccessibilityLabel("\(item.0) settings")
            sidebarButtons.append(button)
        }
        let note = label("A place for every window.", size: 11, color: .secondaryLabelColor)
        note.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(note)
        NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 17),
                                     note.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20)])
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 13
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                                     column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
                                     column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
                                     column.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
                                     column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)])
    }

    @objc private func selectPage(_ sender: NSButton) {
        page = sender.tag
        render()
        window?.contentView?.layoutSubtreeIfNeeded()
        if let scrollView {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func render() {
        stopRecording()
        column.arrangedSubviews.forEach { column.removeArrangedSubview($0); $0.removeFromSuperview() }
        actions.removeAll(); recorderButtons.removeAll()
        for button in sidebarButtons {
            let selected = button.tag == page
            button.layer?.backgroundColor = selected ? stashTint.cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? .white : .labelColor
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        switch page {
        case 1: shortcutsPage()
        case 2: appearancePage()
        default: stashPage()
        }
    }

    private func stashPage() {
        header("Stash", "Keep useful windows at the edge of your current desktop. Reveal them without rearranging your workspace.")
        add(toggle("Enable Stash", value: preferences.enabled) { $0.enabled = $1 })
        section("Window stacks")
        add(toggle("Stack windows from the same app", value: preferences.stackByApp) { $0.stackByApp = $1 })
        add(description("One indicator per app and edge. Click the indicator or use Cycle App Stack to move through its windows. Stashes stay on the desktop where you created them. Opening a stash focuses its window. Moving that window unstashes it; resizing remembers the new size."))
        section("Reveal & dismiss")
        let dismissal = NSPopUpButton()
        dismissal.addItems(withTitles: ["When the cursor leaves", "Only when I press Escape"])
        dismissal.selectItem(at: preferences.dismissMode == .pointerLeaves ? 0 : 1)
        bind(dismissal) { [weak self] sender in
            self?.change { $0.dismissMode = (sender as! NSPopUpButton).indexOfSelectedItem == 0 ? .pointerLeaves : .escape }
            self?.render()
        }
        add(row("Hide revealed windows", dismissal))
        add(description(preferences.dismissMode == .escape
                        ? "Escape slides a revealed window back into its stash. Moving the cursor or focus away leaves it open. Escape never closes the document or quits its app."
                        : "A revealed window returns to its stash after the cursor leaves its window and the notes. Hovering another note keeps it open."))
        add(slider("Reveal delay", value: preferences.showDelay, limits: 0...1, unit: "s") { $0.showDelay = $1 })
        let hide = slider("Hide delay", value: preferences.hideDelay, limits: 0...2, unit: "s") { $0.hideDelay = $1 }
        hide.alphaValue = preferences.dismissMode == .escape ? 0.5 : 1
        if let controls = hide.arrangedSubviews.last as? NSStackView {
            controls.arrangedSubviews.compactMap { $0 as? NSSlider }.forEach { $0.isEnabled = preferences.dismissMode != .escape }
        }
        add(hide)
        section("Motion")
        add(toggle("Slide windows open and closed", value: preferences.animate) { $0.animate = $1 })
        add(slider("Slide duration", value: preferences.animationDuration, limits: 0.1...0.6, unit: "s") { $0.animationDuration = $1 })
        add(description("Motion follows the stash edge and respects macOS Reduce Motion. Some apps require a minimize fallback when macOS prevents offscreen movement."))
        section("Access & recovery")
        add(row("Allow control of app windows", button("Accessibility…") { [weak self] in self?.onEnableAccessibility() }))
        add(row("Bring every stashed window back", button("Restore All") { [weak self] in self?.onRestoreAll() }))
    }

    private func shortcutsPage() {
        header("Keyboard Shortcuts", "Choose a shortcut, then press your new key combination. Include Control, Option, or Command.")
        for action in ShortcutAction.allCases {
            let record = button(shortcutTitle(preferences.shortcuts[action.rawValue])) { [weak self] in self?.startRecording(action) }
            record.widthAnchor.constraint(equalToConstant: 160).isActive = true
            record.setAccessibilityLabel("Record shortcut for \(action.title)")
            recorderButtons[action] = record
            let clear = button("Clear") { [weak self] in
                self?.change { $0.shortcuts.removeValue(forKey: action.rawValue) }
                self?.render()
            }
            clear.setAccessibilityLabel("Clear shortcut for \(action.title)")
            let controls = NSStackView(views: [record, clear]); controls.spacing = 8
            add(row(action.title, controls))
        }
        recordingMessage.font = .systemFont(ofSize: 12)
        recordingMessage.textColor = .secondaryLabelColor
        recordingMessage.stringValue = "Shortcuts work globally. Clear a shortcut to turn that command off."
        add(recordingMessage)
        section("Defaults")
        add(row("Return all shortcuts to the original keys", button("Restore Defaults") { [weak self] in
            self?.change { $0.shortcuts = Preferences.defaultShortcuts }
            self?.render()
        }))
        add(description("The Escape key is reserved for hiding revealed stashes when Escape mode is selected, and for canceling shortcut recording."))
    }

    private func appearancePage() {
        header("Appearance", "Make edge indicators comfortable to see and easy to reach.")
        let preview = IndicatorPreview()
        preview.preferences = preferences
        preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
        preview.setAccessibilityLabel("Preview of the indicator size and color")
        self.preview = preview
        add(preview)
        section("Indicator size")
        add(slider("Thickness", value: preferences.indicatorWidth, limits: 0...48, unit: "pt") { $0.indicatorWidth = $1 })
        add(description("Set thickness to 0 for an icon-only indicator. With icons hidden too, an invisible 1-point edge strip still reveals the stash."))
        add(slider("Height", value: preferences.indicatorHeight, limits: 24...320, unit: "pt") { $0.indicatorHeight = $1 })
        add(slider("Corner radius", value: preferences.indicatorCornerRadius, limits: 0...24, unit: "pt") { $0.indicatorCornerRadius = $1 })
        add(slider("Gap", value: preferences.indicatorGap, limits: 0...48, unit: "pt") { $0.indicatorGap = $1 })
        add(description("Drag a sticky note to move it. Release to snap to an available screen edge; the center and ends attract the note. Positions are saved per app, edge, and display. Open notes keep their slots so neighboring targets stay still."))
        add(row("Reset note positions", button("Reset Positions") { [weak self] in self?.change { $0.indicatorAnchors = [:] } }))
        add(toggle("Show app icon", value: preferences.showAppIcon) { $0.showAppIcon = $1 })
        if preferences.showAppIcon {
            add(slider("App icon size", value: preferences.appIconSize, limits: 16...64, unit: "pt") { $0.appIconSize = $1 })
        }
        add(description("Icons sit inside their sticky notes and fit the selected height. Open windows hide their note until they return to the stash."))
        section("Material")
        add(toggle("Liquid Glass indicators", value: preferences.glassIndicators) { $0.glassIndicators = $1 })
        add(description("Uses untinted Liquid Glass on macOS 26 or later, with frosted glass on older versions. Turn it off to use indicator colors."))
        if preferences.glassIndicators { return }
        section("Colors")
        add(toggle("Use app brand color", value: preferences.useAppBrandColor) { $0.useAppBrandColor = $1 })
        add(description("Uses the dominant color from each app’s icon. Per-app colors below take priority; icons without a clear color use the default."))
        let color = colorWell(preferences.indicatorColor) { [weak self] value in self?.change { $0.indicatorColor = value } }
        color.setAccessibilityLabel("Default indicator color")
        add(row("Default indicator color", color))
        if apps.isEmpty {
            add(description("Stash an app to choose its own indicator color here. Other apps use the selected brand-color or default-color setting."))
        } else {
            add(description("App colors override the brand/default color. Reset an app to use the automatic color again."))
            for app in apps {
                let well = colorWell(preferences.appColors[app.id] ?? preferences.indicatorColor) { [weak self] value in
                    self?.change { $0.appColors[app.id] = value }
                }
                well.setAccessibilityLabel("Indicator color for \(app.name)")
                let reset = button("Reset") { [weak self] in
                    self?.change { $0.appColors.removeValue(forKey: app.id) }; self?.render()
                }
                reset.setAccessibilityLabel("Reset indicator color for \(app.name)")
                let controls = NSStackView(views: [well, reset]); controls.spacing = 8
                add(row(app.name, controls))
            }
        }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        recorderButtons[action]?.title = "Press keys…"
        recordingMessage.stringValue = "Recording \(action.title). Escape cancels; Delete clears."
        recordingMessage.textColor = .secondaryLabelColor
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.change { $0.shortcuts.removeValue(forKey: action.rawValue) }
                self.stopRecording(); return nil
            }
            let flags = event.modifierFlags
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            if let error = shortcutValidationError(shortcut, action: action, in: self.preferences) {
                self.recordingMessage.stringValue = error
                self.recordingMessage.textColor = .systemRed
                return nil
            }
            self.change { $0.shortcuts[action.rawValue] = shortcut }
            self.stopRecording(); return nil
        }
    }

    private func stopRecording() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        recorderMonitor = nil
        if let recording {
            recorderButtons[recording]?.title = shortcutTitle(preferences.shortcuts[recording.rawValue])
            recordingMessage.stringValue = "Shortcuts work globally. Clear a shortcut to turn that command off."
            recordingMessage.textColor = .secondaryLabelColor
        }
        recording = nil
    }

    private func change(_ edit: (inout Preferences) -> Void) {
        let old = preferences
        edit(&preferences)
        preferences.normalize()
        preview?.preferences = preferences
        onChange(preferences)
        if old.glassIndicators != preferences.glassIndicators || old.showAppIcon != preferences.showAppIcon { render() }
    }

    private func bind(_ control: NSControl, _ run: @escaping (NSControl) -> Void) {
        let action = SettingsAction(run); actions.append(action)
        control.target = action; control.action = #selector(SettingsAction.invoke(_:))
    }

    private func button(_ title: String, _ run: @escaping () -> Void) -> NSButton {
        let control = NSButton(title: title, target: nil, action: nil)
        control.bezelStyle = .rounded
        bind(control) { _ in run() }
        return control
    }

    private func colorWell(_ hex: String, _ changed: @escaping (String) -> Void) -> NSColorWell {
        let control = NSColorWell()
        control.color = colorFromHex(hex)
        control.widthAnchor.constraint(equalToConstant: 48).isActive = true
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        bind(control) { changed(hexFromColor(( $0 as! NSColorWell).color)) }
        return control
    }

    private func toggle(_ title: String, value: Bool, _ edit: @escaping (inout Preferences, Bool) -> Void) -> NSView {
        let control = NSSwitch()
        control.state = value ? .on : .off
        control.setAccessibilityLabel(title)
        bind(control) { [weak self] sender in self?.change { edit(&$0, (sender as! NSSwitch).state == .on) } }
        return row(title, control)
    }

    private func slider(_ title: String, value: Double, limits: ClosedRange<Double>, unit: String,
                        _ edit: @escaping (inout Preferences, Double) -> Void) -> NSStackView {
        let control = NSSlider(value: value, minValue: limits.lowerBound, maxValue: limits.upperBound, target: nil, action: nil)
        control.isContinuous = true
        control.setAccessibilityLabel(title)
        control.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let measurement = label(formatted(value, unit: unit), size: 12, color: .secondaryLabelColor)
        measurement.alignment = .right
        measurement.widthAnchor.constraint(equalToConstant: 54).isActive = true
        bind(control) { [weak self] sender in
            let value = (sender as! NSSlider).doubleValue
            measurement.stringValue = self?.formatted(value, unit: unit) ?? ""
            self?.change { edit(&$0, value) }
        }
        let controls = NSStackView(views: [control, measurement]); controls.spacing = 8
        return row(title, controls)
    }

    private func formatted(_ value: Double, unit: String) -> String {
        unit == "pt" ? "\(Int(value.rounded())) pt" : String(format: "%.2f s", value)
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func description(_ text: String) -> NSTextField { label(text, size: 12, color: .secondaryLabelColor) }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let name = label(title)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, NSView(), control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 29).isActive = true
        return row
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func header(_ title: String, _ subtitle: String) {
        add(label(title, size: 25, weight: .semibold))
        add(label(subtitle, size: 13, color: .secondaryLabelColor))
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(25, after: last) }
    }

    private func section(_ title: String) {
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(22, after: last) }
        let separator = NSBox(); separator.boxType = .separator
        add(separator)
        add(label(title, size: 13, weight: .semibold))
    }
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
