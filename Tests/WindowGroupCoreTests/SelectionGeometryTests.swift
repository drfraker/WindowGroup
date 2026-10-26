import Foundation
import CoreGraphics
import XCTest
@testable import WindowGroupCore

final class SelectionGeometryTests: XCTestCase {
    func testMarqueeWorksInEveryDragDirection() {
        let expected = CGRect(x: 20, y: 40, width: 180, height: 260)
        let oppositeCorners = [
            (CGPoint(x: 20, y: 40), CGPoint(x: 200, y: 300)),
            (CGPoint(x: 200, y: 300), CGPoint(x: 20, y: 40)),
            (CGPoint(x: 20, y: 300), CGPoint(x: 200, y: 40)),
            (CGPoint(x: 200, y: 40), CGPoint(x: 20, y: 300))
        ]
        for (start, end) in oppositeCorners {
            XCTAssertEqual(SelectionGeometry.marquee(start, end), expected)
        }
    }

    func testNegativeMonitorCoordinatesAndCenterSelection() {
        let marquee = SelectionGeometry.marquee(CGPoint(x: -100, y: -50), CGPoint(x: -500, y: -200))
        XCTAssertEqual(marquee, CGRect(x: -500, y: -200, width: 400, height: 150))
        XCTAssertTrue(SelectionGeometry.containsWindowCenter(
            window: CGRect(x: -450, y: -180, width: 100, height: 80), in: marquee))
        XCTAssertFalse(SelectionGeometry.containsWindowCenter(
            window: CGRect(x: 0, y: 0, width: 100, height: 80), in: marquee))
    }

    func testPartialIntersectionDoesNotSelectWindowUntilCenterIsIncluded() {
        let window = CGRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertFalse(SelectionGeometry.containsWindowCenter(
            window: window, in: CGRect(x: 0, y: 0, width: 140, height: 140)))
        XCTAssertTrue(SelectionGeometry.containsWindowCenter(
            window: window, in: CGRect(x: 0, y: 0, width: 150, height: 150)))
        XCTAssertTrue(SelectionGeometry.containsWindowCenter(
            window: window, in: CGRect(x: 150, y: 150, width: 1, height: 1)))
    }

    func testSelectedIndicesKeepInputOrder() {
        let frames = [
            CGRect(x: 100, y: 100, width: 100, height: 100),
            CGRect(x: 600, y: 600, width: 100, height: 100),
            CGRect(x: 200, y: 100, width: 100, height: 100)
        ]
        XCTAssertEqual(SelectionGeometry.selectedIndices(
            frames: frames, marquee: CGRect(x: 120, y: 120, width: 150, height: 80)), [0, 2])
    }

    func testCommandClickUsesFrontmostContainingWindow() {
        let frames = [
            CGRect(x: 10, y: 10, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 200, height: 200)
        ]
        XCTAssertEqual(SelectionGeometry.topmostIndex(at: CGPoint(x: 50, y: 50), framesFrontToBack: frames), 0)
        XCTAssertEqual(SelectionGeometry.topmostIndex(at: CGPoint(x: 150, y: 150), framesFrontToBack: frames), 1)
        XCTAssertNil(SelectionGeometry.topmostIndex(at: CGPoint(x: 250, y: 250), framesFrontToBack: frames))
    }

    func testEmptyOrInvalidGeometryNeverSelectsAWindow() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let point = CGPoint(x: 50, y: 50)
        XCTAssertFalse(SelectionGeometry.containsWindowCenter(window: window, in: SelectionGeometry.marquee(point, point)))
        XCTAssertFalse(SelectionGeometry.containsWindowCenter(window: .zero, in: window))
        XCTAssertFalse(SelectionGeometry.containsWindowCenter(window: .null, in: window))
        XCTAssertEqual(SelectionGeometry.marquee(CGPoint(x: CGFloat.nan, y: 0), .zero), .zero)
        XCTAssertNil(SelectionGeometry.topmostIndex(at: CGPoint(x: CGFloat.infinity, y: 0), framesFrontToBack: [window]))
        XCTAssertEqual(SelectionGeometry.topmostIndex(at: point, framesFrontToBack: [.zero, .null, window]), 2)
    }
}
