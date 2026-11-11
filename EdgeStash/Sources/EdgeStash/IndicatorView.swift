import AppKit
import EdgeStashCore

private final class ScopeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// This ordered, transparent window retains desktop membership independently of hidden indicators.
final class StashScope {
    let marker: NSWindow
    var isActive: Bool { marker.isOnActiveSpace }

    init(screen: NSRect) {
        marker = ScopeWindow(contentRect: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 1),
            styleMask: .borderless, backing: .buffered, defer: false)
        marker.alphaValue = 0
        marker.ignoresMouseEvents = true
        marker.canHide = false
        marker.isReleasedWhenClosed = false
        marker.isExcludedFromWindowsMenu = true
        marker.collectionBehavior = [.stationary, .ignoresCycle]
        marker.orderFrontRegardless()
    }
}

func dominantAppIconColor(_ icon: NSImage?) -> NSColor? {
    guard let icon,
          let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: pixels) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
    icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    var buckets: [Int: (count: Int, red: CGFloat, green: CGFloat, blue: CGFloat)] = [:]
    for y in 0..<32 {
        for x in 0..<32 {
            guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.5, color.saturationComponent > 0.2,
                  color.brightnessComponent > 0.15 else { continue }
            let key = (Int(color.redComponent * 7) << 6) | (Int(color.greenComponent * 7) << 3) | Int(color.blueComponent * 7)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.count += 1; bucket.red += color.redComponent
            bucket.green += color.greenComponent; bucket.blue += color.blueComponent
            buckets[key] = bucket
        }
    }
    guard let best = buckets.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }).first?.value else { return nil }
    let count = CGFloat(best.count)
    return NSColor(srgbRed: best.red / count, green: best.green / count, blue: best.blue / count, alpha: 1)
}

private final class IndicatorLayer: NSView {
    var drawing: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawing?() }
}

final class IndicatorButton: NSButton {
    var icon: NSImage?
    var showIcon = true
    var iconSize: CGFloat = 32
    var usesGlass = false
    var cornerRadius: CGFloat = 8
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    private var mouseOrigin: CGPoint?
    private var originalCenter = CGPoint.zero
    private(set) var isDragging = false
    var count = 1
    var edge: Edge = .left
    var thickness: CGFloat = 24
    var tint = NSColor.systemTeal

    private let surface = IndicatorLayer()
    private let artwork = IndicatorLayer()
    private var material: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        surface.drawing = { [weak self] in self?.drawBar() }
        artwork.drawing = { [weak self] in self?.drawArtwork() }
        addSubview(surface); addSubview(artwork)
    }
    required init?(coder: NSCoder) { nil }

    var barFrame: CGRect {
        if thickness > 0 { return bounds }
        switch edge {
        case .left: return CGRect(x: 0, y: 0, width: thickness, height: bounds.height)
        case .right: return CGRect(x: bounds.maxX - thickness, y: 0, width: thickness, height: bounds.height)
        case .top: return CGRect(x: 0, y: bounds.maxY - thickness, width: bounds.width, height: thickness)
        case .bottom: return CGRect(x: 0, y: 0, width: bounds.width, height: thickness)
        }
    }

    private var radius: CGFloat { min(cornerRadius, surface.bounds.width / 2, surface.bounds.height / 2) }
    private var extendedSurface: CGRect {
        let rect = surface.bounds
        // Clip the outer corners past the display edge; only the inward corners remain rounded.
        switch edge {
        case .left: return CGRect(x: -radius, y: 0, width: rect.width + radius, height: rect.height)
        case .right: return CGRect(x: 0, y: 0, width: rect.width + radius, height: rect.height)
        case .top: return CGRect(x: 0, y: 0, width: rect.width, height: rect.height + radius)
        case .bottom: return CGRect(x: 0, y: -radius, width: rect.width, height: rect.height + radius)
        }
    }

    override func layout() {
        super.layout()
        surface.frame = barFrame; artwork.frame = bounds
        if usesGlass && thickness > 0 && material == nil {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular; glass.tintColor = nil
                material = glass
            } else {
                let glass = NSVisualEffectView()
                glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
                material = glass
            }
            surface.addSubview(material!)
        }
        material?.isHidden = !usesGlass || thickness <= 0
        material?.frame = extendedSurface
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.cornerRadius = radius }
        if let fallback = material as? NSVisualEffectView {
            fallback.wantsLayer = true; fallback.layer?.cornerRadius = radius; fallback.layer?.masksToBounds = true
        }
        surface.needsDisplay = true; artwork.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { artwork.needsDisplay = true }

    private func drawBar() {
        guard !usesGlass, thickness > 0 else { return }
        tint.setFill()
        NSBezierPath(roundedRect: extendedSurface, xRadius: radius, yRadius: radius).fill()
    }

    var iconTileFrame: CGRect {
        let side = max(0, min(iconSize, bounds.width - 8, bounds.height - 12))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.rightMouseDown(with: event); return }
        mouseOrigin = window?.convertPoint(toScreen: event.locationInWindow)
        originalCenter = window?.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)) ?? .zero
        isDragging = false
        // NSButton consumes tracking events; explicitly keep this gesture until mouse-up.
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { mouseUp(with: next); break }
            mouseDragged(with: next)
            window?.displayIfNeeded()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin else { return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? origin
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if hypot(delta.x, delta.y) >= 4 { isDragging = true }
        if isDragging { onDragChanged?(CGPoint(x: originalCenter.x + delta.x, y: originalCenter.y + delta.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil else { return }
        if isDragging { onDragEnded?(window?.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)) ?? .zero) }
        else { performClick(nil) }
        mouseOrigin = nil; isDragging = false
    }

    private func drawArtwork() {
        let bar = barFrame
        let tile = iconTileFrame
        if showIcon, tile.width > 0 { icon?.draw(in: tile) }
        if count > 1 {
            let text = String(count) as NSString
            let color = tint.usingColorSpace(.sRGB) ?? .systemTeal
            let brightness = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: usesGlass ? NSColor.labelColor : (brightness > 0.6 ? NSColor.black : NSColor.white)]
            let size = text.size(withAttributes: attributes)
            let position = CGPoint(x: showIcon ? max(2, bounds.maxX - size.width - 3) : bounds.midX - size.width / 2,
                y: showIcon ? max(2, bounds.maxY - size.height - 2) : bounds.midY - size.height / 2)
            text.draw(at: position, withAttributes: attributes)
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bar.insetBy(dx: 2, dy: 2), xRadius: max(0, radius - 2), yRadius: max(0, radius - 2)).stroke()
        }
    }
}
