import Foundation
import CoreGraphics
import XCTest
@testable import WindowGroupCore

final class GridGeometryTests: XCTestCase {
    func testSixCellsFillBoundsWithExactGapsAndNoOverlap() {
        let bounds = CGRect(x: 100, y: 50, width: 916, height: 608)
        let cells = GridGeometry().frames(in: bounds)

        XCTAssertEqual(cells.count, 6)
        XCTAssertTrue(cells.allSatisfy { $0.size == CGSize(width: 300, height: 300) })
        XCTAssertEqual(cells[0].origin, bounds.origin)
        XCTAssertEqual(cells[5].maxX, bounds.maxX)
        XCTAssertEqual(cells[5].maxY, bounds.maxY)
        XCTAssertEqual(cells[1].minX - cells[0].maxX, 8)
        XCTAssertEqual(cells[2].minX - cells[1].maxX, 8)
        XCTAssertEqual(cells[3].minY - cells[0].maxY, 8)
        for first in cells.indices {
            for second in cells.indices where second > first {
                XCTAssertFalse(cells[first].intersects(cells[second]))
            }
        }
    }

    func testRemaindersAreDistributedAndFractionalEdgesStayInsideBounds() {
        let bounds = CGRect(x: 10.2, y: 20.7, width: 1000.5, height: 601.6)
        let cells = GridGeometry().frames(in: bounds)
        XCTAssertEqual(cells[0].minX, 11)
        XCTAssertEqual(cells[0].minY, 21)
        XCTAssertEqual(cells[2].maxX, floor(bounds.maxX))
        XCTAssertEqual(cells[5].maxY, floor(bounds.maxY))
        XCTAssertLessThanOrEqual(cells.map(\.width).max()! - cells.map(\.width).min()!, 1)
        XCTAssertLessThanOrEqual(cells.map(\.height).max()! - cells.map(\.height).min()!, 1)
        for cell in cells {
            XCTAssertTrue(bounds.contains(cell))
            for edge in [cell.minX, cell.minY, cell.maxX, cell.maxY] {
                XCTAssertEqual(edge, edge.rounded())
            }
        }
    }

    func testNegativeMonitorOriginsRemainInAccessibilityCoordinates() {
        let bounds = CGRect(x: -1910, y: -1030, width: 916, height: 608)
        let cells = GridGeometry().frames(in: bounds)
        XCTAssertEqual(cells[0], CGRect(x: -1910, y: -1030, width: 300, height: 300))
        XCTAssertEqual(cells[5], CGRect(x: -1294, y: -722, width: 300, height: 300))
    }

    func testMinimumIncludesAllGapsAndRoundsCellMinimumUp() {
        let minimum = GridGeometry().minimumBoundsSize(cellMinimum: CGSize(width: 200.2, height: 100.1))
        XCTAssertEqual(minimum, CGSize(width: 619, height: 210))
        XCTAssertTrue(GridGeometry().frames(in: CGRect(origin: .zero, size: minimum))
            .allSatisfy { $0.width >= 200.2 && $0.height >= 100.1 })
    }

    func testInvalidGapsAndSmallBoundsNeverProduceNegativeCells() {
        for gap in [CGFloat(-8), CGFloat.nan, CGFloat.infinity] {
            XCTAssertEqual(GridGeometry(gap: gap).gap, 0)
        }
        let cells = GridGeometry(gap: 100).frames(in: CGRect(x: 0, y: 0, width: 3, height: 1))
        XCTAssertEqual(cells.count, 6)
        XCTAssertTrue(cells.allSatisfy { $0.width >= 0 && $0.height >= 0 })
        XCTAssertTrue(cells.allSatisfy { $0.maxX <= 3 && $0.maxY <= 1 })
        let singleCell = GridGeometry(columns: 0, rows: -1).frames(in: CGRect(x: 0, y: 0, width: 30, height: 20))
        XCTAssertEqual(singleCell, [CGRect(x: 0, y: 0, width: 30, height: 20)])
    }

    func testClampSizesAndPlacesGroupInsideNegativeOriginDisplay() {
        let display = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let clamped = GridGeometry().clamp(
            bounds: CGRect(x: -100, y: -50, width: 4000, height: 10),
            to: display,
            minimumSize: CGSize(width: 600, height: 400)
        )
        XCTAssertEqual(clamped, CGRect(x: -1920, y: -400, width: 1920, height: 400))
        XCTAssertTrue(display.contains(clamped))
    }

    func testMovementStopsAtBothDisplayEdgesWithoutChangingSize() {
        let geometry = GridGeometry()
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let original = CGRect(x: -1500, y: 100, width: 900, height: 600)
        XCTAssertEqual(
            geometry.move(original: original, delta: CGPoint(x: -5000, y: -5000), in: display),
            CGRect(x: -1920, y: 0, width: 900, height: 600)
        )
        XCTAssertEqual(
            geometry.move(original: original, delta: CGPoint(x: 5000, y: 5000), in: display),
            CGRect(x: -900, y: 480, width: 900, height: 600)
        )
    }

    func testResizePreservesOriginAndHonorsMinimumAndDisplayEdges() {
        let geometry = GridGeometry()
        let display = CGRect(x: -1920, y: -100, width: 1920, height: 1180)
        let original = CGRect(x: -1500, y: 100, width: 900, height: 600)
        let minimum = CGSize(width: 600, height: 400)
        XCTAssertEqual(
            geometry.resize(original: original, delta: CGPoint(x: -5000, y: -5000), minimumSize: minimum, in: display),
            CGRect(x: -1500, y: 100, width: 600, height: 400)
        )
        XCTAssertEqual(
            geometry.resize(original: original, delta: CGPoint(x: 5000, y: 5000), minimumSize: minimum, in: display),
            CGRect(x: -1500, y: 100, width: 1500, height: 980)
        )
    }

    func testImpossibleMinimumIsPreservedForCallerToReject() {
        let display = CGRect(x: 0, y: 0, width: 500, height: 400)
        let result = GridGeometry().clamp(
            bounds: CGRect(x: 20, y: 20, width: 300, height: 200),
            to: display,
            minimumSize: CGSize(width: 700, height: 600)
        )
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 700, height: 600))
    }
}
