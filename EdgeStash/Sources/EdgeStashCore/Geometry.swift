import Foundation
import CoreGraphics

public enum Edge: String, Codable, CaseIterable {
    case left, right, top, bottom

    public var title: String { rawValue.capitalized }

    public func revealedFrame(_ original: CGRect, screen: CGRect, inset: CGFloat = 30) -> CGRect {
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

    public func tabFrame(screen: CGRect, index: Int, count: Int, width: CGFloat = 24, length preferredLength: CGFloat = 72, anchor: CGFloat? = nil) -> CGRect {
        let vertical = self == .left || self == .right
        let extent = vertical ? screen.height : screen.width
        let length = min(preferredLength, floor(extent / CGFloat(max(count, 1))))
        let thickness = min(width, vertical ? screen.width : screen.height)
        let start = vertical ? screen.minY : screen.minX
        let groupLength = CGFloat(max(count, 1)) * length
        let origin = min(max((anchor ?? start) - length / 2, start), start + extent - groupLength)
        let offset = origin + CGFloat(index) * length
        switch self {
        case .left: return CGRect(x: screen.minX, y: offset, width: thickness, height: length)
        case .right: return CGRect(x: screen.maxX - thickness, y: offset, width: thickness, height: length)
        case .top: return CGRect(x: offset, y: screen.minY, width: length, height: thickness)
        case .bottom: return CGRect(x: offset, y: screen.maxY - thickness, width: length, height: thickness)
        }
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
