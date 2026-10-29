// Deterministic regression tests for delayed global mouse event delivery.
// Uses the production gesture tracker, with no AppKit, permissions or XCTest.
import CoreGraphics
import Foundation

private enum Checks {
    static var assertions = 0
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1
        if !condition {
            failures += 1
            print("  Assertion failed: \(message) (\(file):\(line))")
        }
    }
}

private struct GestureSuite {
    func testStoredEventCoordinatesRecognizeDelayedDrag() {
        var tracker = SelectionGestureTracker()
        // When a global event callback runs late, the live cursor may already be
        // at the mouse-up location while the original mouse-down event is older.
        var cursor = CGPoint(x: 90, y: 140)
        let mouseDownEventPosition = cursor
        cursor = CGPoint(x: 210, y: 140)
        let mouseUpEventPosition = cursor
        tracker.mouseDown(at: mouseDownEventPosition)
        Checks.expect(tracker.mouseUp(at: mouseUpEventPosition, clickCount: 1, shift: false),
                      "A delayed drag must use different original down/up coordinates")
    }

    func testSingleClickAndSubthresholdMovementDoNotSelect() {
        var tracker = SelectionGestureTracker()
        tracker.mouseDown(at: CGPoint(x: 20, y: 30))
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 20, y: 30), clickCount: 1, shift: false),
                      "An ordinary click must not request lookup")
        tracker.mouseDown(at: CGPoint(x: 20, y: 30))
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 22, y: 32), clickCount: 1, shift: false),
                      "Movement below three points must not request lookup")
    }

    func testThreePointThresholdAndNegativeCoordinates() {
        var tracker = SelectionGestureTracker()
        tracker.mouseDown(at: CGPoint(x: -500, y: -70))
        Checks.expect(tracker.mouseUp(at: CGPoint(x: -497, y: -70), clickCount: 1, shift: false),
                      "An exactly three-point drag must be accepted on any display")
        tracker.mouseDown(at: CGPoint(x: -500, y: -70))
        Checks.expect(tracker.mouseUp(at: CGPoint(x: -503, y: -74), clickCount: 1, shift: false),
                      "Drag distance must be independent of direction")
    }

    func testDoubleClickAndTripleClickWithoutMovement() {
        var tracker = SelectionGestureTracker()
        let point = CGPoint(x: 200, y: 200)
        for clickCount in [2, 3] {
            tracker.mouseDown(at: point)
            Checks.expect(tracker.mouseUp(at: point, clickCount: clickCount, shift: false),
                          "Multiple click selection must work without a drag")
        }
    }

    func testShiftSelectionWithoutMovement() {
        var tracker = SelectionGestureTracker()
        let point = CGPoint(x: 200, y: 200)
        tracker.mouseDown(at: point)
        Checks.expect(tracker.mouseUp(at: point, clickCount: 1, shift: true),
                      "Shift-click may extend a selection without local movement")
    }

    func testOrphanMouseUpNeverSelects() {
        var tracker = SelectionGestureTracker()
        let point = CGPoint(x: 800, y: 200)
        Checks.expect(!tracker.mouseUp(at: point, clickCount: 1, shift: false),
                      "A mouse-up with no observed mouse-down must be ignored")
        Checks.expect(!tracker.mouseUp(at: point, clickCount: 2, shift: false),
                      "A multiple-click count cannot replace a missing mouse-down")
        Checks.expect(!tracker.mouseUp(at: point, clickCount: 1, shift: true),
                      "Shift cannot replace a missing mouse-down")
    }

    func testResetDiscardsStaleMouseDown() {
        var tracker = SelectionGestureTracker()
        tracker.mouseDown(at: CGPoint(x: 0, y: 0))
        tracker.reset()
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 100, y: 0), clickCount: 2, shift: true),
                      "Reset must discard a gesture when focus or interaction changes")
        tracker.mouseDown(at: CGPoint(x: 50, y: 50))
        Checks.expect(tracker.mouseUp(at: CGPoint(x: 70, y: 50), clickCount: 1, shift: false),
                      "A fresh gesture must work after reset")
    }

    func testMouseUpConsumesBothAcceptedAndRejectedGesture() {
        var tracker = SelectionGestureTracker()
        tracker.mouseDown(at: CGPoint(x: 0, y: 0))
        Checks.expect(tracker.mouseUp(at: CGPoint(x: 10, y: 0), clickCount: 1, shift: false),
                      "First drag must select")
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 50, y: 0), clickCount: 2, shift: false),
                      "An accepted drag cannot be reused by a second mouse-up")
        tracker.mouseDown(at: CGPoint(x: 20, y: 20))
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 20, y: 20), clickCount: 1, shift: false),
                      "Ordinary click must be rejected")
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 70, y: 20), clickCount: 1, shift: false),
                      "A rejected click cannot leave a stale starting point")
    }

    func testNewMouseDownReplacesPreviousStart() {
        var tracker = SelectionGestureTracker()
        tracker.mouseDown(at: CGPoint(x: 0, y: 0))
        tracker.mouseDown(at: CGPoint(x: 500, y: 500))
        Checks.expect(!tracker.mouseUp(at: CGPoint(x: 500, y: 500), clickCount: 1, shift: false),
                      "An interrupted mouse-down must not create a false long drag")
    }
}

@main private struct SelectionTests {
    static func main() {
        print("WordSlide selection gesture regression tests (no AppKit / XCTest)")
        let suite = GestureSuite()
        let cases: [(String, () -> Void)] = [
            ("testStoredEventCoordinatesRecognizeDelayedDrag", suite.testStoredEventCoordinatesRecognizeDelayedDrag),
            ("testSingleClickAndSubthresholdMovementDoNotSelect", suite.testSingleClickAndSubthresholdMovementDoNotSelect),
            ("testThreePointThresholdAndNegativeCoordinates", suite.testThreePointThresholdAndNegativeCoordinates),
            ("testDoubleClickAndTripleClickWithoutMovement", suite.testDoubleClickAndTripleClickWithoutMovement),
            ("testShiftSelectionWithoutMovement", suite.testShiftSelectionWithoutMovement),
            ("testOrphanMouseUpNeverSelects", suite.testOrphanMouseUpNeverSelects),
            ("testResetDiscardsStaleMouseDown", suite.testResetDiscardsStaleMouseDown),
            ("testMouseUpConsumesBothAcceptedAndRejectedGesture", suite.testMouseUpConsumesBothAcceptedAndRejectedGesture),
            ("testNewMouseDownReplacesPreviousStart", suite.testNewMouseDownReplacesPreviousStart)
        ]
        var failedTests = 0
        for (name, run) in cases {
            let before = Checks.failures
            run()
            if before == Checks.failures { print("PASS \(name)") }
            else { failedTests += 1; print("FAIL \(name)") }
        }
        print("\(cases.count) gesture tests, \(Checks.assertions) assertions, \(failedTests) failed tests.")
        if failedTests > 0 { exit(1) }
    }
}
