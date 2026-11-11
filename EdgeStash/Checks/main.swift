import CoreGraphics
import EdgeStashCore

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checkCount += 1
}

let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
let window = CGRect(x: -1300, y: 0, width: 600, height: 400)
for edge in Edge.allCases {
    let frame = edge.hiddenFrame(window, screen: screen)
    check(frame.size == window.size, "Stash must preserve window size")
    let intersection = frame.intersection(screen)
    check((edge == .left || edge == .right ? intersection.width : intersection.height) == 2, "Only a two-point sliver should remain")
    let tabs = (0..<100).map { edge.tabFrame(screen: screen, index: $0, count: 100, length: window.height) }
    check(tabs.allSatisfy { screen.contains($0) }, "Tabs must fit on their display")
    check(!tabs[0].intersects(tabs[1]), "Adjacent tabs must not overlap")
}
let right = CGRect(x: 0, y: -200, width: 1920, height: 1080)
check(Edge.right.isShared(screen: screen, others: [right]), "Adjacent monitor edge must be rejected")
check(!Edge.left.isShared(screen: screen, others: [right]), "Outside monitor edge must remain available")
check(!Edge.right.isShared(screen: screen, others: [CGRect(x: 0, y: 800, width: 100, height: 100)]), "Separated monitors do not share an edge")
check(Edge.right.isBlocked(window: window, screen: screen, others: [CGRect(x: 20, y: 0, width: 1000, height: 800)]), "A hidden window must not enter a display across a small gap")
check(!Edge.right.isBlocked(window: window, screen: screen, others: [CGRect(x: 1000, y: 0, width: 1000, height: 800)]), "Distant displays must not block an edge")
check(flip(flip(screen, primaryHeight: 900), primaryHeight: 900) == screen, "AX/AppKit conversion must round-trip")
let target = CGRect(x: 0, y: 0, width: 800, height: 600)
let centered = CGRect(x: 200, y: 150, width: 400, height: 300)
let otherIndicator = CGRect(x: 0, y: 0, width: 40, height: 80)
check(stashKeepsOpen(pointer: CGPoint(x: 10, y: 30), window: centered, trigger: nil, indicators: [otherIndicator]),
    "Hovering another indicator must keep an open stash stable")
check(!stashKeepsOpen(pointer: CGPoint(x: 100, y: 100), window: centered, trigger: nil, indicators: [otherIndicator]),
    "Empty desktop between an indicator and window must still dismiss")
check(Edge.left.revealedFrame(centered, screen: target).minX == target.minX,
    "A revealed window must occupy the edge space freed by its indicator")
let centeredTab = Edge.left.tabFrame(screen: target, index: 0, count: 1, length: 48)
check(centeredTab.midY == target.midY, "A single indicator must remain vertically centered")
let firstSharedTab = Edge.left.tabFrame(screen: target, index: 0, count: 2, length: 48)
let secondSharedTab = Edge.left.tabFrame(screen: target, index: 1, count: 2, length: 48)
check(firstSharedTab.height == 48 && secondSharedTab.height == 48, "Multiple sticky notes must honor the selected height")
check((firstSharedTab.minY + secondSharedTab.maxY) / 2 == target.midY, "The combined indicator group must stay centered")
check(secondSharedTab.minY - firstSharedTab.maxY == 8, "Sticky notes must honor the configured gap")
check(centeredTab.height == 48, "A sticky note must default to 48 points independently of its window")
for count in [2, 3, 7, 20] {
    let tabs = (0..<count).map { Edge.right.tabFrame(screen: screen, index: $0, count: count, length: 48) }
    check(tabs.allSatisfy { $0.height <= 48 && screen.contains($0) }, "Notes must retain their selected height or shrink only to fit the display")
    check(abs((tabs.first!.minY + tabs.last!.maxY) / 2 - screen.midY) < 0.001, "Centered layouts must work on negative-coordinate displays")
}
check(Edge.left.revealedFrame(centered, screen: target).minX == target.minX, "Reveal must stay beside its stash edge instead of returning to the center")
check(Edge.right.revealedFrame(centered, screen: target).maxX == target.maxX, "Right reveal must stay at the right edge")
check(Edge.top.revealedFrame(centered, screen: target).minY == target.minY, "Top reveal must stay at the top edge")
check(Edge.bottom.revealedFrame(centered, screen: target).maxY == target.maxY, "Bottom reveal must stay at the bottom edge")
check(Edge.left.revealedFrame(window, screen: screen).minY == window.minY, "Reveal must preserve the perpendicular position")
check(Edge.left.revealedFrame(centered, screen: target).size == centered.size, "Reveal must preserve size when it fits")
check(centered.minX == 200, "Unstash must retain the original frame separately")
for edge in Edge.allCases {
    let tab = edge.tabFrame(screen: screen, index: 0, count: 1, length: 96, width: 32)
    check((edge == .left || edge == .right ? tab.width : tab.height) == 32, "Indicator thickness must follow settings")
    check(screen.contains(tab), "Custom indicator must remain on the source display")
    for iconSize in [16.0, 32, 64] {
        let panel = edge.indicatorPanelFrame(bar: tab, showIcon: true, iconSize: iconSize)
        check(screen.contains(panel) && panel.contains(tab), "Every icon size must protrude inward without leaving the screen")
    }
    let floating = edge.indicatorPanelFrame(bar: tab, showIcon: true)
    check(screen.contains(floating) && floating.contains(tab), "The floating icon must protrude inward, within its display")
    check(edge.indicatorPanelFrame(bar: tab, showIcon: false) == tab, "Hidden icons must leave no invisible protruding hit area")
}
for edge in Edge.allCases {
    let bar = edge.tabFrame(screen: target, index: 0, count: 1, length: 300, width: 0)
    let iconOnly = edge.indicatorPanelFrame(bar: bar, showIcon: true, iconSize: 64)
    check(target.contains(iconOnly) && !iconOnly.isEmpty, "Zero thickness must retain an accessible floating icon on every edge")
    let invisible = edge.indicatorPanelFrame(bar: bar, showIcon: false)
    check(target.contains(invisible) && (edge == .left || edge == .right ? invisible.width : invisible.height) == 1,
        "Zero thickness with icons hidden must retain only an invisible one-point inward hover strip")
}
check(slideFrame(from: centered, to: target, progress: 0) == centered, "A slide must start at its actual frame")
check(slideFrame(from: centered, to: target, progress: 1) == target, "A slide must finish exactly at its destination")
check(slideFrame(from: centered, to: target, progress: 0.5).minX < centered.minX / 2, "Ease-out motion must progress toward the edge")
let hoverRegion = stashHoverRegion(window: CGRect(x: 30, y: 100, width: 400, height: 300), trigger: CGRect(x: 0, y: 150, width: 40, height: 200))
check(hoverRegion.contains(CGPoint(x: 2, y: 200)), "Hiding the indicator must still let the pointer enter a zero-delay reveal")
check(!hoverRegion.contains(CGPoint(x: 500, y: 500)), "Leaving both window and trigger must still dismiss the reveal")
check(stashHoverRegion(window: centered, trigger: nil) == centered, "Non-indicator reveals must preserve the window hover area")
check(fitting(CGRect(x: -1400, y: -50, width: 1000, height: 900), inside: target) == target, "Restore must fit a smaller remaining display")
check(framesMatch(window.offsetBy(dx: 2, dy: 0), window), "Small AX rounding is tolerated")
check(!framesMatch(window.offsetBy(dx: 10, dy: 0), window), "A refused restore must be detected")
check(!framesMatch(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), window), "Invalid AX geometry must be rejected")
let anchored = Edge.left.tabFrames(screen: target, count: 3, length: 48, width: 24, gap: 12, anchors: [0.9, 0.9, 0.9])
let sortedAnchors = anchored.sorted { $0.minY < $1.minY }
check(anchored.allSatisfy { target.contains($0) }, "Dragged notes must fit their display even when anchors collide")
check(zip(sortedAnchors, sortedAnchors.dropFirst()).allSatisfy { $1.minY - $0.maxY >= 11.999 }, "Dragged notes must keep their configured gap")
check(Edge.nearest(to: CGPoint(x: 799, y: 100), screen: target) == .right, "A released note must snap to its nearest edge")
check(Edge.nearest(to: CGPoint(x: 1, y: 100), screen: target, allowed: [.right, .top]) == .top, "Snapping must exclude shared display edges")
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: 295), screen: target, length: 48) == 0.5, "Notes must magnetically align to the display center")
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: -200), screen: target, length: 48) == 24.0 / 600, "Dragged notes must clamp to the end of their edge")
checkHoverIntent()
checkPreferences()
checkWindowGeometry()
print("Passed \(checkCount) geometry checks (including 400 tab containment cases).")
