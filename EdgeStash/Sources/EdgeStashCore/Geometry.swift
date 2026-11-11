import Foundation
import CoreGraphics

public enum Edge: String, Codable, CaseIterable {
    case left, right, top, bottom

    public var title: String { rawValue.capitalized }

    public func revealedFrame(_ original: CGRect, screen: CGRect, inset: CGFloat = 0, indicator: CGRect? = nil) -> CGRect {
        let margin = min(max(0, inset), min(screen.width, screen.height) / 4)
        let available = screen.insetBy(dx: margin, dy: margin)
        var result = fitting(original, inside: available)
        if let indicator {
            if self == .left || self == .right { result.origin.y = indicator.midY - result.height / 2 }
            else { result.origin.x = indicator.midX - result.width / 2 }
        }
        switch self {
        case .left: result.origin.x = available.minX
        case .right: result.origin.x = available.maxX - result.width
        case .top: result.origin.y = available.minY
        case .bottom: result.origin.y = available.maxY - result.height
        }
        return fitting(result, inside: available)
    }

    public func hiddenFrame(_ window: CGRect, screen: CGRect, sliver: CGFloat = 2) -> CGRect {
        var result = window
        switch self {
        case .left: result.origin.x = screen.minX - window.width + sliver
        case .right: result.origin.x = screen.maxX - sliver
        case .top: result.origin.y = screen.minY - window.height + sliver
        case .bottom: result.origin.y = screen.maxY - sliver
        }
        return result
    }

    public func cornerFallbacks(_ window: CGRect, screen: CGRect, others: [CGRect]) -> [CGRect] {
        guard self == .top || self == .bottom else { return [] }
        return [Edge.left, .right].filter { !$0.isBlocked(window: window, screen: screen, others: others) }
            .map { $0.hiddenFrame(window, screen: screen) }
            .sorted { abs($0.minX - window.minX) < abs($1.minX - window.minX) }
    }

    public func windowSlideFrame(from origin: CGRect, to destination: CGRect, progress: Double) -> CGRect {
        var aligned = origin
        switch self {
        case .left, .right: aligned.origin.y = destination.minY
        case .top, .bottom: aligned.origin.x = destination.minX
        }
        return slideFrame(from: aligned, to: destination, progress: progress)
    }

    public func isShared(screen: CGRect, others: [CGRect]) -> Bool {
        others.contains { other in
            let overlapX = min(screen.maxX, other.maxX) - max(screen.minX, other.minX)
            let overlapY = min(screen.maxY, other.maxY) - max(screen.minY, other.minY)
            switch self {
            case .left: return abs(screen.minX - other.maxX) < 2 && overlapY > 0
            case .right: return abs(screen.maxX - other.minX) < 2 && overlapY > 0
            case .top: return abs(screen.minY - other.maxY) < 2 && overlapX > 0
            case .bottom: return abs(screen.maxY - other.minY) < 2 && overlapX > 0
            }
        }
    }

    public func tabFrame(screen: CGRect, index: Int, count: Int, length: CGFloat = 48, width: CGFloat = 24, gap: CGFloat = 8) -> CGRect {
        tabFrames(screen: screen, count: max(1, count), length: length, width: width, gap: gap)[min(max(index, 0), max(0, count - 1))]
    }

    public func tabFrames(screen: CGRect, count: Int, length: CGFloat, width: CGFloat, gap: CGFloat,
                          anchors: [Double?] = []) -> [CGRect] {
        guard count > 0 else { return [] }
        let vertical = self == .left || self == .right
        let extent = max(0, vertical ? screen.height : screen.width)
        let spacing = min(max(0, gap), max(0, extent / CGFloat(count) - 1))
        let size = min(max(1, length), max(0, (extent - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let total = size * CGFloat(count) + spacing * CGFloat(count - 1)
        var result: [CGRect] = []
        let thickness = min(max(0, width), vertical ? screen.width : screen.height)
        let axisStart = vertical ? screen.minY : screen.minX
        let axisEnd = vertical ? screen.maxY : screen.maxX
        for index in 0..<count {
            let anchor: Double? = index < anchors.count ? anchors[index] : nil
            // Manual positions bypass automatic packing and keep their own height and spacing.
            let noteSize = anchor == nil ? size : min(max(1, length), extent)
            let natural = (extent - total) / 2 + CGFloat(index) * (size + spacing)
            let position = anchor.map { CGFloat($0) * extent - noteSize / 2 } ?? natural
            let offset = min(max(axisStart + position, axisStart), max(axisStart, axisEnd - noteSize))
            let fittedSize = min(noteSize, max(0, axisEnd - offset))
            switch self {
            case .left: result.append(CGRect(x: screen.minX, y: offset, width: thickness, height: fittedSize))
            case .right: result.append(CGRect(x: screen.maxX - thickness, y: offset, width: thickness, height: fittedSize))
            case .top: result.append(CGRect(x: offset, y: screen.minY, width: fittedSize, height: thickness))
            case .bottom: result.append(CGRect(x: offset, y: screen.maxY - thickness, width: fittedSize, height: thickness))
            }
        }
        return result
    }

    public func indicatorPanelFrame(bar: CGRect, showIcon: Bool, iconSize: CGFloat = 32, iconOffset: CGFloat = 0) -> CGRect {
        let vertical = self == .left || self == .right
        let length = vertical ? bar.height : bar.width
        let thickness = vertical ? bar.width : bar.height
        let icon = min(iconSize, max(0, length - 12))
        let center = max(icon / 2 + 6, thickness / 2) + max(0, iconOffset)
        let targetWidth = showIcon ? max(thickness, center + icon / 2 + 6) : max(1, thickness)
        switch self {
        case .left: return CGRect(x: bar.minX, y: bar.minY, width: targetWidth, height: bar.height)
        case .right: return CGRect(x: bar.maxX - targetWidth, y: bar.minY, width: targetWidth, height: bar.height)
        case .top: return CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: targetWidth)
        case .bottom: return CGRect(x: bar.minX, y: bar.maxY - targetWidth, width: bar.width, height: targetWidth)
        }
    }

    public func avoidingObstruction(_ panel: CGRect, screen: CGRect, obstruction: CGRect?) -> CGRect {
        guard self == .top || self == .bottom, let obstruction, panel.intersects(obstruction) else { return panel }
        let leftGap = min(8, max(0, obstruction.minX - screen.minX - 1))
        let rightGap = min(8, max(0, screen.maxX - obstruction.maxX - 1))
        let leftEnd = min(screen.maxX, max(screen.minX, obstruction.minX - leftGap))
        let rightStart = min(screen.maxX, max(screen.minX, obstruction.maxX + rightGap))
        let areas = [CGRect(x: screen.minX, y: screen.minY, width: leftEnd - screen.minX, height: screen.height),
                     CGRect(x: rightStart, y: screen.minY, width: screen.maxX - rightStart, height: screen.height)]
            .filter { $0.width > 0 }
        let fullSize = areas.filter { $0.width >= panel.width }
        let widest = areas.map(\.width).max() ?? 0
        let candidates = fullSize.isEmpty ? areas.filter { $0.width == widest } : fullSize
        if let result = candidates.map({ fitting(panel, inside: $0) })
            .min(by: { abs($0.minX - panel.minX) < abs($1.minX - panel.minX) }) { return result }
        if self == .bottom {
            // shortcut: a Dock filling the whole edge leaves only a one-point side target until space is available.
            return CGRect(x: screen.minX, y: screen.maxY - panel.height, width: min(1, screen.width), height: panel.height)
        }
        // Only a display with no usable space beside its cutout needs an inward fallback.
        return fitting(panel.offsetBy(dx: 0, dy: obstruction.maxY - panel.minY), inside: screen)
    }

    public func magneticAnchor(point: CGPoint, screen: CGRect, length: CGFloat, neighbors: [CGRect] = []) -> Double {
        let vertical = self == .left || self == .right
        let extent = vertical ? screen.height : screen.width
        guard extent > 0 else { return 0.5 }
        let half = min(max(0, length), extent) / 2
        let start = vertical ? screen.minY : screen.minX
        var coordinate = (vertical ? point.y : point.x) - start
        let stops = [half, extent / 2, extent - half] + neighbors.flatMap { note -> [CGFloat] in
            [(vertical ? note.minY : note.minX) - start - half,
             (vertical ? note.maxY : note.maxX) - start + half]
        }
        if let nearest = stops.min(by: { abs($0 - coordinate) < abs($1 - coordinate) }), abs(nearest - coordinate) <= 8 {
            coordinate = nearest
        }
        return Double(min(max(coordinate, half), extent - half) / extent)
    }

    public func isBlocked(window: CGRect, screen: CGRect, others: [CGRect]) -> Bool {
        isShared(screen: screen, others: others) || others.contains {
            let overlap = hiddenFrame(window, screen: screen).intersection($0)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }
}

public func slideFrame(from: CGRect, to: CGRect, progress: Double) -> CGRect {
    let t = min(max(progress, 0), 1)
    let eased = 1 - pow(1 - t, 3)
    return CGRect(x: from.minX + (to.minX - from.minX) * eased,
                  y: from.minY + (to.minY - from.minY) * eased,
                  width: from.width + (to.width - from.width) * eased,
                  height: from.height + (to.height - from.height) * eased)
}

public func stashHoverRegion(window: CGRect, trigger: CGRect?) -> CGRect {
    trigger.map { window.union($0) } ?? window
}

public func stashKeepsOpen(pointer: CGPoint, window: CGRect, trigger: CGRect?, indicators: [CGRect]) -> Bool {
    stashHoverRegion(window: window, trigger: trigger).contains(pointer) || indicators.contains { $0.contains(pointer) }
}

// Accessibility coordinates start at the primary display's top-left; AppKit starts at its bottom-left.
public func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

public func fitting(_ rect: CGRect, inside screen: CGRect) -> CGRect {
    let width = min(rect.width, screen.width)
    let height = min(rect.height, screen.height)
    return CGRect(x: min(max(rect.minX, screen.minX), screen.maxX - width),
                  y: min(max(rect.minY, screen.minY), screen.maxY - height), width: width, height: height)
}

public func framesMatch(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 3) -> Bool {
    zip([actual.minX, actual.minY, actual.width, actual.height],
        [expected.minX, expected.minY, expected.width, expected.height]).allSatisfy {
        $0.isFinite && $1.isFinite && abs($0 - $1) <= tolerance
    }
}

public func windowIsHidden(_ window: CGRect, on screens: [CGRect], sliver: CGFloat = 3) -> Bool {
    guard !screens.isEmpty else { return false }
    return screens.allSatisfy {
        let overlap = window.intersection($0)
        return overlap.isNull || overlap.width <= sliver || overlap.height <= sliver
    }
}

public func bottomDockObstruction(_ dock: CGRect, screen: CGRect) -> CGRect? {
    guard [dock.minX, dock.minY, dock.width, dock.height].allSatisfy(\.isFinite),
          dock.width > dock.height, dock.height > 0, dock.height < screen.height / 2,
          dock.minY >= screen.midY, dock.minY <= screen.maxY + dock.height, dock.maxY >= screen.maxY - 32,
          dock.minX < screen.maxX, dock.maxX > screen.minX else { return nil }
    let left = max(screen.minX, dock.minX), right = min(screen.maxX, dock.maxX)
    // Reserve the full Dock height even while auto-hide moves its window below the display.
    let height = max(dock.height, screen.maxY - dock.minY)
    return CGRect(x: left, y: screen.maxY - height, width: right - left, height: height)
}
