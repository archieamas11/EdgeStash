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
    let tabs = (0..<100).map { edge.tabFrame(screen: screen, index: $0, count: 100) }
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
check(Edge.left.revealedFrame(centered, screen: target).minX == 30, "Reveal must stay beside its stash edge instead of returning to the center")
check(Edge.right.revealedFrame(centered, screen: target).maxX == target.maxX - 30, "Right reveal must stay at the right edge")
check(Edge.top.revealedFrame(centered, screen: target).minY == target.minY + 30, "Top reveal must stay at the top edge")
check(Edge.bottom.revealedFrame(centered, screen: target).maxY == target.maxY - 30, "Bottom reveal must stay at the bottom edge")
check(Edge.left.revealedFrame(window, screen: screen).minY == window.minY, "Reveal must preserve the perpendicular position")
check(Edge.left.revealedFrame(centered, screen: target).size == centered.size, "Reveal must preserve size when it fits")
check(centered.minX == 200, "Unstash must retain the original frame separately")
for edge in Edge.allCases {
    let tab = edge.tabFrame(screen: screen, index: 0, count: 1, width: 32, length: 96, anchor: window.midY)
    check((edge == .left || edge == .right ? tab.width : tab.height) == 32, "Indicator thickness must follow settings")
    check(screen.contains(tab), "Custom indicator must remain on the source display")
}
check(slideFrame(from: centered, to: target, progress: 0) == centered, "A slide must start at its actual frame")
check(slideFrame(from: centered, to: target, progress: 1) == target, "A slide must finish exactly at its destination")
check(slideFrame(from: centered, to: target, progress: 0.5).minX < centered.minX / 2, "Ease-out motion must progress toward the edge")
check(fitting(CGRect(x: -1400, y: -50, width: 1000, height: 900), inside: target) == target, "Restore must fit a smaller remaining display")
check(framesMatch(window.offsetBy(dx: 2, dy: 0), window), "Small AX rounding is tolerated")
check(!framesMatch(window.offsetBy(dx: 10, dy: 0), window), "A refused restore must be detected")
check(!framesMatch(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), window), "Invalid AX geometry must be rejected")
checkPreferences()
print("Passed \(checkCount) geometry checks (including 400 tab containment cases).")
