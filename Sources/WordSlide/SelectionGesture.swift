import CoreGraphics

/// Tracks a mouse selection from immutable event coordinates. Global events can
/// arrive after the cursor has moved, so callers must pass the original event's
/// position rather than sampling the current mouse position when processing it.
struct SelectionGestureTracker {
    private var startPoint: CGPoint?

    mutating func mouseDown(at point: CGPoint) {
        startPoint = point
    }

    mutating func mouseUp(at point: CGPoint, clickCount: Int, shift: Bool) -> Bool {
        defer { startPoint = nil }
        guard let startPoint else { return false }
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        return dx * dx + dy * dy >= 9 || clickCount >= 2 || shift
    }

    mutating func reset() {
        startPoint = nil
    }
}
