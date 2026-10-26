import Foundation
import CoreGraphics

/// Geometry in the Accessibility coordinate system: the origin is at the top left.
/// Cell edges use whole coordinate units so adjacent windows line up exactly.
public struct GridGeometry: Sendable {
    public let columns: Int
    public let rows: Int
    public let gap: CGFloat

    public init(columns: Int = 3, rows: Int = 2, gap: CGFloat = 8) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.gap = Self.nonnegativeFinite(gap).rounded()
    }

    /// Returns cells in row-major order. Uneven dimensions are distributed so
    /// cells differ by at most one coordinate unit and the last edge fits exactly.
    /// If the bounds are too small for the requested gaps, gaps shrink to fit.
    public func frames(in bounds: CGRect) -> [CGRect] {
        let bounds = Self.finiteRect(bounds)
        let left = ceil(bounds.minX)
        let top = ceil(bounds.minY)
        let width = max(0, floor(bounds.maxX) - left)
        let height = max(0, floor(bounds.maxY) - top)
        let horizontalGap = columns > 1 ? min(gap, floor(width / CGFloat(columns - 1))) : 0
        let verticalGap = rows > 1 ? min(gap, floor(height / CGFloat(rows - 1))) : 0
        let cellWidthTotal = max(0, width - horizontalGap * CGFloat(columns - 1))
        let cellHeightTotal = max(0, height - verticalGap * CGFloat(rows - 1))

        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let x0 = floor(cellWidthTotal * CGFloat(column) / CGFloat(columns))
                let x1 = floor(cellWidthTotal * CGFloat(column + 1) / CGFloat(columns))
                let y0 = floor(cellHeightTotal * CGFloat(row) / CGFloat(rows))
                let y1 = floor(cellHeightTotal * CGFloat(row + 1) / CGFloat(rows))
                return CGRect(
                    x: left + x0 + horizontalGap * CGFloat(column),
                    y: top + y0 + verticalGap * CGFloat(row),
                    width: max(0, x1 - x0),
                    height: max(0, y1 - y0)
                )
            }
        }
    }

    public func minimumBoundsSize(cellMinimum: CGSize) -> CGSize {
        CGSize(
            width: ceil(Self.nonnegativeFinite(cellMinimum.width)) * CGFloat(columns)
                + gap * CGFloat(columns - 1),
            height: ceil(Self.nonnegativeFinite(cellMinimum.height)) * CGFloat(rows)
                + gap * CGFloat(rows - 1)
        )
    }

    /// Constrains the size, then translates the rectangle onto the display.
    /// An impossible minimum remains authoritative and is anchored to the
    /// display's origin; callers should reject that case before applying frames.
    public func clamp(bounds: CGRect, to display: CGRect, minimumSize: CGSize) -> CGRect {
        let bounds = Self.finiteRect(bounds)
        let display = Self.finiteRect(display)
        let minimum = Self.finiteSize(minimumSize)
        let size = CGSize(
            width: max(minimum.width, min(bounds.width, display.width)),
            height: max(minimum.height, min(bounds.height, display.height))
        )
        return CGRect(
            x: max(display.minX, min(bounds.minX, display.maxX - size.width)),
            y: max(display.minY, min(bounds.minY, display.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    /// Moves the group without changing its size, stopping at display edges.
    public func move(original: CGRect, delta: CGPoint, in display: CGRect) -> CGRect {
        let original = Self.finiteRect(original)
        let translated = original.offsetBy(
            dx: Self.finite(delta.x),
            dy: Self.finite(delta.y)
        )
        return clamp(bounds: translated, to: display, minimumSize: original.size)
    }

    /// Resizes from the bottom-right corner, keeping the top-left fixed.
    /// If a minimum cannot fit from that origin, it is preserved; the caller
    /// should validate that the original group can accommodate its minimum.
    public func resize(
        original: CGRect,
        delta: CGPoint,
        minimumSize: CGSize,
        in display: CGRect
    ) -> CGRect {
        let original = Self.finiteRect(original)
        let display = Self.finiteRect(display)
        let minimum = Self.finiteSize(minimumSize)
        let availableWidth = max(0, display.maxX - original.minX)
        let availableHeight = max(0, display.maxY - original.minY)
        return CGRect(
            origin: original.origin,
            size: CGSize(
                width: max(minimum.width, min(original.width + Self.finite(delta.x), availableWidth)),
                height: max(minimum.height, min(original.height + Self.finite(delta.y), availableHeight))
            )
        )
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0
    }

    private static func nonnegativeFinite(_ value: CGFloat) -> CGFloat {
        max(0, finite(value))
    }

    private static func finiteSize(_ size: CGSize) -> CGSize {
        CGSize(width: nonnegativeFinite(size.width), height: nonnegativeFinite(size.height))
    }

    private static func finiteRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: finite(rect.origin.x),
            y: finite(rect.origin.y),
            width: nonnegativeFinite(rect.size.width),
            height: nonnegativeFinite(rect.size.height)
        )
    }
}
