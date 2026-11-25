import Foundation
import CoreGraphics

public struct HoverIntent<ID: Hashable> {
    private var candidate: ID?
    private var enteredAt = 0.0
    private var blockedRegion: CGRect?
    public var isWaiting: Bool { candidate != nil }

    public init() {}

    public mutating func cancel(blocking region: CGRect? = nil) {
        candidate = nil; blockedRegion = region
    }

    public mutating func target(pointer: CGPoint, targets: [(id: ID, frame: CGRect)], now: Double,
                                delay: Double, transitioning: Bool, mouseDown: Bool) -> ID? {
        if let region = blockedRegion {
            if region.contains(pointer) { candidate = nil; return nil }
            blockedRegion = nil
        }
        guard !transitioning, !mouseDown, let hit = targets.first(where: { $0.frame.contains(pointer) }) else {
            candidate = nil; return nil
        }
        if candidate != hit.id { candidate = hit.id; enteredAt = now }
        guard now - enteredAt >= delay else { return nil }
        cancel(blocking: hit.frame.insetBy(dx: -2, dy: -2))
        return hit.id
    }
}
