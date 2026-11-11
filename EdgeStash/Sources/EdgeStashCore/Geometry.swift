import Foundation
import CoreGraphics

public enum Edge: String, Codable, CaseIterable {
    case left, right, top, bottom

    public var title: String { rawValue.capitalized }

    public func revealedFrame(_ original: CGRect, screen: CGRect, inset: CGFloat = 0) -> CGRect {
        let margin = min(max(0, inset), min(screen.width, screen.height) / 4)
        let available = screen.insetBy(dx: margin, dy: margin)
        var result = fitting(original, inside: available)
        switch self {
        case .left: result.origin.x = available.minX
        case .right: result.origin.x = available.maxX - result.width
        case .top: result.origin.y = available.minY
        case .bottom: result.origin.y = available.maxY - result.height
        }
        return result
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
        var positions: [(index: Int, start: CGFloat)] = []
        for index in 0..<count {
            let anchor: Double? = index < anchors.count ? anchors[index] : nil
            let natural = (extent - total) / 2 + CGFloat(index) * (size + spacing)
            let start: CGFloat = anchor.map { CGFloat($0) * extent - size / 2 } ?? natural
            positions.append((index, min(max(0, start), max(0, extent - size))))
        }
        positions.sort { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }
        var cursor: CGFloat = 0
        for i in positions.indices {
            positions[i].start = max(cursor, positions[i].start)
            cursor = positions[i].start + size + spacing
        }
        cursor = extent
        for i in positions.indices.reversed() {
            positions[i].start = min(positions[i].start, cursor - size)
            cursor = positions[i].start - spacing
        }
        var result = Array(repeating: CGRect.zero, count: count)
        let thickness = min(max(0, width), vertical ? screen.width : screen.height)
        for item in positions {
            let start = vertical ? screen.minY : screen.minX
            let end = vertical ? screen.maxY : screen.maxX
            let offset = min(max(start + item.start, start), max(start, end - size))
            let fittedSize = min(size, max(0, end - offset))
            switch self {
            case .left: result[item.index] = CGRect(x: screen.minX, y: offset, width: thickness, height: fittedSize)
            case .right: result[item.index] = CGRect(x: screen.maxX - thickness, y: offset, width: thickness, height: fittedSize)
            case .top: result[item.index] = CGRect(x: offset, y: screen.minY, width: fittedSize, height: thickness)
            case .bottom: result[item.index] = CGRect(x: offset, y: screen.maxY - thickness, width: fittedSize, height: thickness)
            }
        }
        return result
    }

    public func indicatorPanelFrame(bar: CGRect, showIcon: Bool, iconSize: CGFloat = 32) -> CGRect {
        let vertical = self == .left || self == .right
        let length = vertical ? bar.height : bar.width
        let thickness = vertical ? bar.width : bar.height
        let icon = min(iconSize, max(0, length - 12))
        let targetWidth = showIcon ? max(thickness, icon + (thickness > 0 ? 12 : 8)) : max(1, thickness)
        switch self {
        case .left: return CGRect(x: bar.minX, y: bar.minY, width: targetWidth, height: bar.height)
        case .right: return CGRect(x: bar.maxX - targetWidth, y: bar.minY, width: targetWidth, height: bar.height)
        case .top: return CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: targetWidth)
        case .bottom: return CGRect(x: bar.minX, y: bar.maxY - targetWidth, width: bar.width, height: targetWidth)
        }
    }

    public static func nearest(to point: CGPoint, screen: CGRect, allowed: [Edge] = Edge.allCases) -> Edge? {
        func distance(_ edge: Edge) -> CGFloat {
            switch edge {
            case .left: return abs(point.x - screen.minX)
            case .right: return abs(point.x - screen.maxX)
            case .top: return abs(point.y - screen.minY)
            case .bottom: return abs(point.y - screen.maxY)
            }
        }
        return allowed.min { distance($0) < distance($1) }
    }

    public func magneticAnchor(point: CGPoint, screen: CGRect, length: CGFloat) -> Double {
        let vertical = self == .left || self == .right
        let extent = vertical ? screen.height : screen.width
        guard extent > 0 else { return 0.5 }
        var coordinate = (vertical ? point.y - screen.minY : point.x - screen.minX)
        for stop in [length / 2, extent / 2, extent - length / 2] where abs(coordinate - stop) <= 12 {
            coordinate = stop; break
        }
        return Double(min(max(coordinate, length / 2), max(length / 2, extent - length / 2)) / extent)
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
