import Foundation
import CoreGraphics

public enum WindowGeometryChange { case none, resized, moved }

public struct WindowGeometry {
    public private(set) var restoreFrame: CGRect
    public private(set) var displayedFrame: CGRect

    public init(original: CGRect) { restoreFrame = original; displayedFrame = original }

    public mutating func didPresent(_ frame: CGRect) { displayedFrame = frame }

    public mutating func observe(_ actual: CGRect) -> WindowGeometryChange {
        guard [actual.minX, actual.minY, actual.width, actual.height].allSatisfy(\.isFinite),
              actual.width > 0, actual.height > 0 else { return .none }
        let movedX = abs(actual.minX - displayedFrame.minX) > 3
        let movedY = abs(actual.minY - displayedFrame.minY) > 3
        // Top/left and centered resizes keep an opposite edge or center fixed; snapping translates them too.
        if actual.size != displayedFrame.size {
            let resizeX = !movedX || abs(actual.maxX - displayedFrame.maxX) <= 3 || abs(actual.midX - displayedFrame.midX) <= 3
            let resizeY = !movedY || abs(actual.maxY - displayedFrame.maxY) <= 3 || abs(actual.midY - displayedFrame.midY) <= 3
            if !resizeX || !resizeY { return .moved }
            restoreFrame.size = actual.size
            displayedFrame = actual
            return .resized
        }
        if movedX || movedY { return .moved }
        return .none
    }
}
