import CoreGraphics
import EdgeStashCore

func checkWindowGeometry() {
    let original = CGRect(x: 400, y: 200, width: 600, height: 400)
    let presented = CGRect(x: 30, y: 200, width: 600, height: 400)
    var geometry = WindowGeometry(original: original)
    geometry.didPresent(presented)
    precondition(geometry.observe(presented) == .none)
    let resized = CGRect(x: -70, y: 100, width: 700, height: 500)
    precondition(geometry.observe(resized) == .resized, "A resize from the top/left must not unstash")
    precondition(geometry.restoreFrame.origin == original.origin)
    precondition(geometry.restoreFrame.size == resized.size, "The next reveal/hide must use the user's new size")
    precondition(geometry.observe(resized) == .none)
    let nextReveal = Edge.left.revealedFrame(geometry.restoreFrame, screen: CGRect(x: 0, y: 0, width: 1400, height: 1000))
    precondition(nextReveal.size == resized.size, "Opening again must not reset the first stashed size")
    geometry.didPresent(nextReveal)
    precondition(geometry.observe(nextReveal) == .none, "Our own reveal must not be treated as a user move")
    precondition(geometry.observe(nextReveal.offsetBy(dx: 40, dy: 20)) == .moved)
    precondition(geometry.observe(CGRect(x: 400, y: 300, width: 800, height: 600)) == .moved,
                 "Moving and resizing together through a snap must unstash")
    let centeredResize = nextReveal.insetBy(dx: -10, dy: -10)
    precondition(geometry.observe(centeredResize) == .resized, "A centered resize must remain stashed")
    geometry.didPresent(nextReveal)
    precondition(geometry.observe(CGRect(origin: nextReveal.origin, size: CGSize(width: nextReveal.width + 1, height: nextReveal.height))) == .resized,
                 "Even a one-point resize must be remembered")
    precondition(geometry.observe(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)) == .none)
    print("Passed resize persistence, top/left resizing, programmatic reveal, and manual-move checks.")
}
