import Foundation

public struct GridLayout: Equatable, Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        precondition(columns > 0 && rows > 0 && columns <= Int.max / rows,
                     "A grid needs positive dimensions and a representable capacity.")
        self.columns = columns
        self.rows = rows
    }

    public var label: String { "\(columns) × \(rows)" }
    public var capacity: Int { columns * rows }

    /// Useful layouts for one through twelve windows, with the recommendation
    /// first. Empty cells are allowed when they make a more balanced grid.
    public static func suggested(for count: Int) -> [GridLayout] {
        guard (1...12).contains(count) else { return [] }
        var layouts: [GridLayout] = []
        func append(_ columns: Int, _ rows: Int) {
            let candidate = GridLayout(columns: columns, rows: rows)
            if !layouts.contains(candidate) { layouts.append(candidate) }
        }
        func appendBothOrientations(_ columns: Int, _ rows: Int) {
            append(columns, rows)
            append(rows, columns)
        }

        // Nine-cell grids give seven through nine windows a stable, balanced
        // default instead of a long strip or a very wide two-row arrangement.
        if (7...9).contains(count) { append(3, 3) }

        let exactFactors = (1...count).compactMap { rows -> GridLayout? in
            guard rows > 1, count % rows == 0 else { return nil }
            let columns = count / rows
            guard columns >= rows else { return nil }
            return GridLayout(columns: columns, rows: rows)
        }.sorted { ($0.columns - $0.rows) < ($1.columns - $1.rows) }

        if exactFactors.isEmpty && layouts.isEmpty {
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = (count + columns - 1) / columns
            appendBothOrientations(columns, rows)
        }
        for factor in exactFactors {
            appendBothOrientations(factor.columns, factor.rows)
        }
        appendBothOrientations(count, 1)
        return Array(layouts.prefix(6))
    }
}
