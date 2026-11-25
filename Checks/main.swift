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
let freeNotes = Edge.left.tabFrames(screen: target, count: 2, length: 48, width: 24, gap: 40, anchors: [0.6, 0.69])
check(abs(freeNotes[0].midY - 360) < 0.001 && abs(freeNotes[1].midY - 414) < 0.001,
    "Individually moved notes must retain their positions without enforcing the automatic gap")
check(anchored.allSatisfy { target.contains($0) }, "Dragged notes must fit their display even when anchors collide")
check(anchored.allSatisfy { abs($0.midY - 540) < 0.001 }, "Deliberately placed notes must not be pushed apart by automatic gap packing")
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: 295), screen: target, length: 48) == 0.5, "Notes must magnetically align to the display center")
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: -200), screen: target, length: 48) == 24.0 / 600, "Dragged notes must clamp to the end of their edge")
let neighbor = CGRect(x: 0, y: 100, width: 40, height: 48)
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: 169), screen: target, length: 48, neighbors: [neighbor]) == 172.0 / 600,
    "A freely positioned note must still magnetically align to a nearby note's edge")
check(Edge.left.magneticAnchor(point: CGPoint(x: 0, y: 200), screen: CGRect(x: 0, y: 0, width: 80, height: 20), length: 48) == 0.5,
    "Magnetic positioning must fit notes taller than the available edge")
let usable = CGRect(x: 0, y: 26, width: 800, height: 520)
let movedNoteDestination = CGRect(x: 400, y: 380, width: 400, height: 160)
let oldRightStash = CGRect(x: 798, y: 40, width: 400, height: 160)
check(Edge.right.windowSlideFrame(from: oldRightStash, to: movedNoteDestination, progress: 0.5).minY == movedNoteDestination.minY,
    "Moving a right-edge note must not animate its window from the old note's vertical position")
let topDestination = CGRect(x: 300, y: 26, width: 400, height: 300)
let leftCorner = CGRect(x: -398, y: 26, width: 400, height: 300)
check(Edge.top.windowSlideFrame(from: leftCorner, to: topDestination, progress: 0.5).minX == topDestination.minX,
    "A top stash must never animate horizontally from its corner fallback")
for edge in Edge.allCases {
    for anchor in [0.0, 0.2, 0.5, 0.8, 1] {
        let bar = edge.tabFrames(screen: target, count: 1, length: 48, width: 24, gap: 0, anchors: [anchor])[0]
        let reveal = edge.revealedFrame(centered, screen: usable, indicator: bar)
        check(usable.contains(reveal), "Indicator-aligned windows must remain inside menu-bar/Dock usable bounds")
        check(reveal.size == centered.size, "Moving a note must not resize its window when it fits")
        let expected = edge == .left || edge == .right
            ? min(max(bar.midY - reveal.height / 2, usable.minY), usable.maxY - reveal.height)
            : min(max(bar.midX - reveal.width / 2, usable.minX), usable.maxX - reveal.width)
        check(abs((edge == .left || edge == .right ? reveal.minY : reveal.minX) - expected) < 0.001,
            "Reveals must follow the note center, clamping only at screen boundaries")
        let hidden = edge.hiddenFrame(reveal, screen: target)
        for progress in [0.0, 0.25, 0.5, 0.75, 1] {
            let opening = edge.windowSlideFrame(from: hidden, to: reveal, progress: progress)
            let closing = edge.windowSlideFrame(from: reveal, to: hidden, progress: progress)
            let vertical = edge == .top || edge == .bottom
            check(vertical ? opening.minX == reveal.minX && closing.minX == reveal.minX
                : opening.minY == reveal.minY && closing.minY == reveal.minY,
                "Opening and closing must move only perpendicular to the stashed edge")
            check(opening.size == reveal.size && closing.size == reveal.size, "Sliding must preserve window size")
            if progress == 1 {
                check(opening == reveal && closing == hidden, "Edge slides must reach their exact destinations")
            }
        }
        let start = edge.hiddenFrame(bar, screen: target, sliver: 0)
        check(!start.intersects(target), "An indicator's return slide must start outside its physical screen edge")
        check(slideFrame(from: start, to: bar, progress: 1) == bar, "Indicator slides must end at their reserved target")
    }
}
let leftDisplay = CGRect(x: -800, y: 0, width: 800, height: 600)
let rightDisplay = CGRect(x: 800, y: 0, width: 800, height: 600)
for edge in [Edge.top, .bottom] {
    let fallback = edge.cornerFallbacks(centered, screen: target, others: [leftDisplay])
    check(fallback.count == 1 && fallback[0].minX == 798, "Top/bottom fallback must choose an outside corner away from a neighboring display")
    check(windowIsHidden(fallback[0], on: [target, leftDisplay]), "Corner fallback must be hidden across every display")
    check(edge.cornerFallbacks(centered, screen: target, others: [leftDisplay, rightDisplay]).isEmpty,
        "No safe horizontal corner must retain the native minimization fallback")
}
check(!windowIsHidden(CGRect(x: 800, y: 0, width: 400, height: 300), on: [target, rightDisplay]),
    "A window on another monitor is not hidden")
check(!windowIsHidden(CGRect(x: -390, y: 100, width: 400, height: 300), on: [target]),
    "A ten-point visible remnant must trigger fallback")
check(windowIsHidden(CGRect(x: -398, y: 100, width: 400, height: 300), on: [target]),
    "A two-point stash sliver remains valid")
check(!windowIsHidden(centered, on: []), "A missing display inventory during sleep/wake cannot prove a window is hidden")
let cutout = CGRect(x: 350, y: 0, width: 100, height: 30)
let topNote = CGRect(x: 376, y: 0, width: 48, height: 44)
let safeNote = Edge.top.avoidingObstruction(topNote, screen: target, obstruction: cutout)
check(safeNote.minY == target.minY && !safeNote.intersects(cutout), "A top note must stay beside the notch at the physical edge, rather than below it")
check(Edge.top.avoidingObstruction(topNote.offsetBy(dx: -200, dy: 0), screen: target, obstruction: cutout).minY == 0,
    "Top notes outside the cutout must remain at the physical screen edge")
for offset in [CGPoint.zero, CGPoint(x: -1920, y: -500), CGPoint(x: 800, y: 600)] {
    let display = target.offsetBy(dx: offset.x, dy: offset.y)
    let notch = cutout.offsetBy(dx: offset.x, dy: offset.y)
    for width in [48.0, 320, 780] {
        for anchor in [0.0, 0.35, 0.5, 0.65, 1] {
            let bar = Edge.top.tabFrames(screen: display, count: 1, length: width, width: 44, gap: 0, anchors: [anchor])[0]
            let safe = Edge.top.avoidingObstruction(bar, screen: display, obstruction: notch)
            check(display.contains(safe) && !safe.intersects(notch), "Dragged notes, including oversized notes, must stay clear of the notch on every display")
            check(safe.minY == display.minY, "Notch avoidance must preserve the top edge")
        }
    }
    let automaticArea = Edge.top.avoidingObstruction(display, screen: display, obstruction: notch)
    for count in 1...8 {
        let notes = Edge.top.tabFrames(screen: automaticArea, count: count, length: 320, width: 44, gap: 8)
        for (index, note) in notes.enumerated() {
            check(display.contains(note) && !note.intersects(notch) && note.minY == display.minY,
                "Default stacks must all fit beside the notch without needing manual positioning")
            if index > 0 { check(!notes[index - 1].intersects(note), "Default notes beside the notch must remain individually accessible") }
        }
    }
}
let dock = CGRect(x: 160, y: target.maxY - 80, width: 480, height: 80)
let bottomNote = CGRect(x: 376, y: target.maxY - 44, width: 48, height: 44)
let besideDock = Edge.bottom.avoidingObstruction(bottomNote, screen: target, obstruction: dock)
check(besideDock.maxY == target.maxY && !besideDock.intersects(dock), "Bottom notes must stay beside the Dock at the bottom edge, never above it")
for offset in [CGPoint.zero, CGPoint(x: -1920, y: -500), CGPoint(x: 800, y: 600)] {
    let display = target.offsetBy(dx: offset.x, dy: offset.y)
    let occupied = dock.offsetBy(dx: offset.x, dy: offset.y)
    check(bottomDockObstruction(occupied, screen: display) == occupied, "Dock bounds must retain their physical display coordinates")
    let hiddenDock = occupied.offsetBy(dx: 0, dy: display.maxY - 2 - occupied.minY)
    check(bottomDockObstruction(hiddenDock, screen: display) == occupied, "Auto-hidden Dock bounds must reserve the full Dock height")
    check(bottomDockObstruction(hiddenDock.offsetBy(dx: 0, dy: 42), screen: display) == occupied, "Fully offscreen auto-hidden icons must retain their side reservation")
    check(bottomDockObstruction(occupied.offsetBy(dx: 0, dy: -1000), screen: display) == nil, "A Dock on another display must not block this edge")
    for width in [48.0, 320, 780] {
        for anchor in [0.0, 0.35, 0.5, 0.65, 1] {
            let bar = Edge.bottom.tabFrames(screen: display, count: 1, length: width, width: 44, gap: 0, anchors: [anchor])[0]
            let safe = Edge.bottom.avoidingObstruction(bar, screen: display, obstruction: occupied)
            check(display.contains(safe) && !safe.intersects(occupied) && safe.maxY == display.maxY,
                "Dragged and oversized bottom notes must stay beside the Dock on every display")
        }
    }
    let side = Edge.bottom.avoidingObstruction(display, screen: display, obstruction: occupied)
    for count in 1...8 {
        let notes = Edge.bottom.tabFrames(screen: side, count: count, length: 320, width: 44, gap: 8)
        for (index, note) in notes.enumerated() {
            check(display.contains(note) && !note.intersects(occupied) && note.maxY == display.maxY, "Default bottom stacks must fit beside the Dock")
            if index > 0 { check(!notes[index - 1].intersects(note), "Bottom notes beside the Dock must remain independently accessible") }
        }
    }
}
check(bottomDockObstruction(CGRect(x: 0, y: 0, width: 80, height: 500), screen: target) == nil, "A vertical Dock is not a bottom Dock")
check(bottomDockObstruction(CGRect(x: CGFloat.infinity, y: 520, width: 480, height: 80), screen: target) == nil, "Invalid Dock metadata must be rejected")
let narrowGapDock = CGRect(x: 4, y: target.maxY - 80, width: target.width - 8, height: 80)
let narrowSide = Edge.bottom.avoidingObstruction(bottomNote, screen: target, obstruction: narrowGapDock)
check(narrowSide.width > 0 && !narrowSide.intersects(narrowGapDock) && narrowSide.maxY == target.maxY,
    "Clearance must shrink before consuming the last accessible side space")
let fullEdgeTarget = Edge.bottom.avoidingObstruction(bottomNote, screen: target, obstruction: CGRect(x: 0, y: 520, width: 800, height: 80))
check(fullEdgeTarget.width == 1 && fullEdgeTarget.maxY == target.maxY && target.contains(fullEdgeTarget),
    "A completely occupied edge must retain an accessible side target rather than moving above the Dock")
checkHoverIntent()
checkPreferences()
checkWindowGeometry()
print("Passed \(checkCount) geometry checks (including 400 tab containment cases).")

for edge in Edge.allCases {
    for full in [true, false] {
        for count in [1, 2, 5, 30] {
            for gap in [0.0, 8, 48] {
                let area = CGRect(x: -500, y: -200, width: 900, height: 700)
                let frames = edge.packedTabFrames(screen: area, count: count, length: 140, width: 1, gap: gap,
                    fullEdge: full, anchors: Array(repeating: 0.9, count: count))
                check(frames.allSatisfy { area.contains($0) }, "Packed notes must stay within their safe edge")
                let sorted = frames.sorted { edge == .left || edge == .right ? $0.minY < $1.minY : $0.minX < $1.minX }
                for i in 1..<sorted.count {

                    let separation = edge == .left || edge == .right ? sorted[i].minY - sorted[i-1].maxY : sorted[i].minX - sorted[i-1].maxX
                    check(separation >= min(gap, 1) - 0.001, "Both modes must preserve a gap when space permits")
                }
                if full && count == 1 {
                    check((edge == .left || edge == .right ? frames[0].height : frames[0].width) == (edge == .left || edge == .right ? area.height : area.width), "A single full-edge note must fill the available edge")
                }
            }
        }
    }
}
let swapFrames = Edge.left.packedTabFrames(screen: screen, count: 2, length: 48, width: 24, gap: 8, fullEdge: true, anchors: [0.75, 0.25])
check(swapFrames[0].midY > swapFrames[1].midY, "Saved slot order must swap indicators")
print("Passed full-edge/custom packing, gaps, crowded edges, colliding anchors and saved swap order on all four edges.")

for edge in [Edge.top, .bottom] {
    let display = CGRect(x: -500, y: -200, width: 1000, height: 700)
    let obstacle = CGRect(x: -80, y: edge == .top ? -200 : 450, width: 160, height: 50)
    let bars = edge.packedTabFrames(screen: display, count: 4, length: 120, width: 8, gap: 10, fullEdge: true, obstruction: obstacle)
    check(bars.contains { $0.midX < obstacle.minX } && bars.contains { $0.midX > obstacle.maxX }, "Horizontal layouts must use both safe sides")
    check(bars.allSatisfy { !$0.intersects(obstacle) && display.contains($0) }, "Distributed indicators must clear the notch or Dock")
    let right = edge.packedTabFrames(screen: display, count: 1, length: 120, width: 8, gap: 10, fullEdge: false, obstruction: obstacle, preferredPosition: 350)
    check(right[0].midX > obstacle.maxX && abs(right[0].width - 120) < 0.001, "A right-side window must default to the right without changing custom length")
}

let anchoredHorizontal = Edge.top.packedTabFrames(screen: CGRect(x: -500, y: 0, width: 1000, height: 700), count: 1,
    length: 120, width: 8, gap: 8, fullEdge: false, anchors: [0.8], obstruction: CGRect(x: -80, y: 0, width: 160, height: 40))
check(abs(anchoredHorizontal[0].midX - 300) < 0.001, "Horizontal anchors must remain in screen coordinates when choosing a safe side")
print("Passed dual-side horizontal packing, custom lengths and screen-relative anchors.")
