import Foundation
import CoreGraphics

/// Coordinate-independent selection helpers. Use one coordinate system for
/// every point and frame supplied to a call.
public enum SelectionGeometry {
    /// A drag can travel in any direction, including across negative origins.
    public static func marquee(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
            return .zero
        }
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width.isFinite, height.isFinite else { return .zero }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: width, height: height)
    }

    /// Select a window only when its center is in the box, including its edges.
    /// A zero-area box selects nothing; merely intersecting a window is insufficient.
    public static func containsWindowCenter(window: CGRect, in selection: CGRect) -> Bool {
        guard let window = validRectangle(window), let selection = validRectangle(selection) else {
            return false
        }
        return contains(CGPoint(x: window.midX, y: window.midY), in: selection)
    }

    public static func selectedIndices(frames: [CGRect], marquee: CGRect) -> [Int] {
        frames.indices.filter { containsWindowCenter(window: frames[$0], in: marquee) }
    }

    /// Frames must be ordered frontmost first. Overlap resolves to that first
    /// containing window, matching the visible window under a Command-click.
    public static func topmostIndex(at point: CGPoint, framesFrontToBack: [CGRect]) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return framesFrontToBack.firstIndex { frame in
            guard let frame = validRectangle(frame) else { return false }
            return contains(point, in: frame)
        }
    }

    private static func validRectangle(_ rectangle: CGRect) -> CGRect? {
        let rectangle = rectangle.standardized
        guard rectangle.minX.isFinite, rectangle.minY.isFinite,
              rectangle.maxX.isFinite, rectangle.maxY.isFinite,
              rectangle.width > 0, rectangle.height > 0 else { return nil }
        return rectangle
    }

    private static func contains(_ point: CGPoint, in rectangle: CGRect) -> Bool {
        point.x >= rectangle.minX && point.x <= rectangle.maxX
            && point.y >= rectangle.minY && point.y <= rectangle.maxY
    }
}
