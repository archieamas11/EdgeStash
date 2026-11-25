import CoreGraphics
import EdgeStashCore

func checkHoverIntent() {
    var hover = HoverIntent<String>()
    let a = (id: "a", frame: CGRect(x: 0, y: 100, width: 48, height: 48))
    let b = (id: "b", frame: CGRect(x: 0, y: 160, width: 48, height: 48))
    func hit(_ point: CGPoint, time: Double, targets: [(id: String, frame: CGRect)], transitioning: Bool = false, down: Bool = false, delay: Double = 0) -> String? {
        hover.target(pointer: point, targets: targets, now: time, delay: delay, transitioning: transitioning, mouseDown: down)
    }
    precondition(hit(CGPoint(x: 10, y: 110), time: 0, targets: [a, b]) == "a")
    precondition(hit(CGPoint(x: 30, y: 125), time: 1, targets: [a, b]) == nil,
        "Moving more than eight points inside a note must not rearm a reveal")
    precondition(hit(CGPoint(x: 30, y: 125), time: 2, targets: [(id: "b", frame: a.frame)]) == nil,
        "A changed target beneath the pointer must not open without a deliberate exit")
    precondition(hit(CGPoint(x: 10, y: 170), time: 3, targets: [b], transitioning: true) == nil,
        "An unfinished slide must not trigger another hover reveal")
    precondition(hit(CGPoint(x: 10, y: 170), time: 4, targets: [b], down: true) == nil,
        "Dragging a sticky note must not reveal it")
    precondition(hit(CGPoint(x: 10, y: 170), time: 5, targets: [b], delay: 0.2) == nil)
    precondition(hit(CGPoint(x: 10, y: 170), time: 5.21, targets: [b], delay: 0.2) == "b")
    precondition(hit(CGPoint(x: 10, y: 170), time: 6, targets: [b]) == nil)
    _ = hit(CGPoint(x: 100, y: 200), time: 7, targets: [b])
    precondition(hit(CGPoint(x: 10, y: 170), time: 8, targets: [b]) == "b",
        "Leaving and entering a note must allow a new reveal")
    print("Passed hover exit/reentry, target replacement, dwell, slide serialization, and drag suppression checks.")
}
