import XCTest
@testable import WindowGroupCore

final class GridLayoutTests: XCTestCase {
    func testEverySupportedCountHasEnoughCapacityAndUniqueBoundedSuggestions() {
        for count in 1...12 {
            let layouts = GridLayout.suggested(for: count)
            XCTAssertFalse(layouts.isEmpty, "No suggestions for \(count)")
            XCTAssertLessThanOrEqual(layouts.count, 6)
            XCTAssertEqual(Set(layouts).count, layouts.count)
            XCTAssertTrue(layouts.allSatisfy { $0.capacity >= count && $0.columns > 0 && $0.rows > 0 })
            XCTAssertTrue(layouts.contains(GridLayout(columns: count, rows: 1)))
            XCTAssertTrue(layouts.contains(GridLayout(columns: 1, rows: count)))
        }
    }

    func testSixWindowsPreferLandscapeExactGridThenPortraitAndStrips() {
        XCTAssertEqual(GridLayout.suggested(for: 6), [
            GridLayout(columns: 3, rows: 2), GridLayout(columns: 2, rows: 3),
            GridLayout(columns: 6, rows: 1), GridLayout(columns: 1, rows: 6)
        ])
    }

    func testFourWindowsPreferSquareAndFiveAllowOneEmptyCell() {
        XCTAssertEqual(GridLayout.suggested(for: 4), [
            GridLayout(columns: 2, rows: 2), GridLayout(columns: 4, rows: 1),
            GridLayout(columns: 1, rows: 4)
        ])
        XCTAssertEqual(GridLayout.suggested(for: 5), [
            GridLayout(columns: 3, rows: 2), GridLayout(columns: 2, rows: 3),
            GridLayout(columns: 5, rows: 1), GridLayout(columns: 1, rows: 5)
        ])
    }

    func testLargerSelectionsRecommendBalancedLayouts() {
        for count in 7...9 {
            XCTAssertEqual(GridLayout.suggested(for: count).first, GridLayout(columns: 3, rows: 3))
        }
        XCTAssertEqual(GridLayout.suggested(for: 11).first, GridLayout(columns: 4, rows: 3))
        XCTAssertEqual(GridLayout.suggested(for: 12).first, GridLayout(columns: 4, rows: 3))
    }

    func testSingleWindowAndUnsupportedCounts() {
        XCTAssertEqual(GridLayout.suggested(for: 1), [GridLayout(columns: 1, rows: 1)])
        for count in [-1, 0, 13, Int.max] {
            XCTAssertTrue(GridLayout.suggested(for: count).isEmpty)
        }
    }

    func testLayoutLabelAndCapacity() {
        let layout = GridLayout(columns: 3, rows: 2)
        XCTAssertEqual(layout.label, "3 × 2")
        XCTAssertEqual(layout.capacity, 6)
    }
}
