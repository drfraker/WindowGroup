import AppKit
import WindowGroupCore

private struct IntegrationCheckFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// Runs only against six explicitly identified disposable fixture windows.
/// Never substitutes a different process or a user's normal editor windows.
/// All captured frames are restored, including after a partial failed apply.
@MainActor
func runIntegrationCheck(fixturePID: pid_t, access: WindowAccess) async -> String {
    guard WindowAccess.isTrusted else {
        return "SKIPPED: WindowGroup needs Accessibility permission before the integration check can run. No windows were changed."
    }
    guard fixturePID > 0,
          fixturePID != ProcessInfo.processInfo.processIdentifier,
          let fixture = NSRunningApplication(processIdentifier: fixturePID),
          fixture.executableURL?.lastPathComponent == "WindowGroupFixture" else {
        return "FAILED: The supplied PID does not identify the WindowGroupFixture executable. No windows were changed."
    }

    let windows = await access.listWindows()
        .filter { $0.pid == fixturePID }
        .sorted { $0.title < $1.title }
    let expectedTitles = Set((1...6).map { "WG Fixture \($0)" })
    guard windows.count == 6, Set(windows.map(\.title)) == expectedTitles else {
        return "FAILED: Expected exactly the six WG Fixture windows for PID \(fixturePID); found \(windows.count). No windows were changed."
    }
    var originals: [CGRect] = []
    for window in windows {
        guard let frame = await access.readFrame(window) else {
            return "FAILED: Could not capture every fixture frame. No windows were changed."
        }
        originals.append(frame)
    }
    guard let primary = NSScreen.screens.first,
          let target = NSScreen.screens.max(by: { first, second in
              first.visibleFrame.width * first.visibleFrame.height < second.visibleFrame.width * second.visibleFrame.height
          }) else {
        return "SKIPPED: No display is available. No windows were changed."
    }
    let visible = target.visibleFrame
    let display = CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY,
                         width: visible.width, height: visible.height)
    let cellMinimum = CGSize(width: 180, height: 160)
    let layoutChecks: [(count: Int, layout: GridLayout)] = [
        (2, GridLayout(columns: 2, rows: 1)),
        (4, GridLayout(columns: 2, rows: 2)),
        (5, GridLayout(columns: 3, rows: 2)),
        (6, GridLayout(columns: 2, rows: 3))
    ]
    let geometry = GridGeometry(columns: 3, rows: 2, gap: 8)
    let minimum = geometry.minimumBoundsSize(cellMinimum: cellMinimum)
    let layoutMinimums = layoutChecks.map {
        GridGeometry(columns: $0.layout.columns, rows: $0.layout.rows, gap: 8)
            .minimumBoundsSize(cellMinimum: cellMinimum)
    }
    let requiredWidth = max(minimum.width + 140, (layoutMinimums.map(\.width).max() ?? 0) + 56)
    let requiredHeight = max(minimum.height + 140, (layoutMinimums.map(\.height).max() ?? 0) + 56)
    guard display.width >= requiredWidth, display.height >= requiredHeight else {
        return "SKIPPED: The display is too small for all variable-layout fixture checks. No windows were changed."
    }
    let initial = CGRect(x: display.minX + 28, y: display.minY + 28,
                         width: max(minimum.width, min(900, display.width - 180)),
                         height: max(minimum.height, min(500, display.height - 180)))
    let moved = geometry.move(original: initial, delta: CGPoint(x: 35, y: 25), in: display)
    let resized = geometry.resize(original: moved, delta: CGPoint(x: 55, y: 45),
                                  minimumSize: minimum, in: display)
    var report = ["WindowGroup fixture integration check (PID \(fixturePID), six windows)"]
    var operationFailure: String?
    do {
        // Increasing prefix sizes leave every unselected suffix in its original
        // position, making accidental changes to unselected windows detectable.
        for check in layoutChecks {
            let layoutGeometry = GridGeometry(columns: check.layout.columns, rows: check.layout.rows, gap: 8)
            let layoutMinimum = layoutGeometry.minimumBoundsSize(cellMinimum: cellMinimum)
            let layoutBounds = CGRect(
                x: display.minX + 28,
                y: display.minY + 28,
                width: max(layoutMinimum.width, min(900, display.width - 56)),
                height: max(layoutMinimum.height, min(600, display.height - 56))
            )
            let selectedWindows = Array(windows.prefix(check.count))
            let selectedFrames = Array(layoutGeometry.frames(in: layoutBounds).prefix(check.count))
            let stage = "Arrange \(check.count) windows in \(check.layout.label)"
            guard selectedFrames.count == selectedWindows.count else {
                throw IntegrationCheckFailure(detail: "\(stage): The grid returned too few cells.")
            }
            for (window, frame) in zip(selectedWindows, selectedFrames) {
                _ = try await access.applyFrame(frame, to: window)
            }
            try await verifyFixtureFrames(selectedFrames, windows: selectedWindows, access: access, stage: stage)

            let unselectedWindows = Array(windows.dropFirst(check.count))
            if !unselectedWindows.isEmpty {
                try await verifyFixtureFrames(
                    Array(originals.dropFirst(check.count)), windows: unselectedWindows,
                    access: access, stage: "\(stage), unselected windows unchanged"
                )
            }
            let emptyCount = check.layout.capacity - check.count
            let emptyDetail = emptyCount > 0 ? " \(emptyCount) cell left empty." : ""
            let unchangedDetail = unselectedWindows.isEmpty
                ? "" : " \(unselectedWindows.count) unselected fixture windows unchanged."
            report.append("PASS: \(stage); selected frames match within 2 points.\(emptyDetail)\(unchangedDetail)")
        }

        for (name, bounds) in [("Arrange 3×2", initial), ("Move group", moved), ("Resize group", resized)] {
            let frames = geometry.frames(in: bounds)
            guard frames.count == windows.count else {
                throw IntegrationCheckFailure(detail: "The grid returned an unexpected window count.")
            }
            for (window, frame) in zip(windows, frames) {
                _ = try await access.applyFrame(frame, to: window)
            }
            try await verifyFixtureFrames(frames, windows: windows, access: access, stage: name)
            report.append("PASS: \(name); all six actual frames match within 2 points.")
        }
        // Exercise the large frames used on ultrawide displays, where some
        // apps settle position/size asynchronously after AX setters return.
        let largeBounds = display.insetBy(dx: 40, dy: 50)
        for layout in [GridLayout(columns: 3, rows: 2), GridLayout(columns: 2, rows: 3)] {
            let largeFrames = GridGeometry(columns: layout.columns, rows: layout.rows).frames(in: largeBounds)
            for (window, frame) in zip(windows, largeFrames) {
                _ = try await access.applyFrame(frame, to: window)
            }
            try await verifyFixtureFrames(largeFrames, windows: windows, access: access, stage: "Large \(layout.label)")
            report.append("PASS: Display-sized \(layout.label) grid; all six actual frames match within 2 points.")
        }
    } catch {
        operationFailure = error.localizedDescription
        report.append("FAIL: \(error.localizedDescription)")
    }

    // This path runs after success or any partial failure. Continue restoration
    // even if one fixture window became unavailable; never stop at the first.
    var restoreErrors: [String] = []
    for (window, original) in zip(windows, originals) {
        do {
            _ = try await access.applyFrame(original, to: window)
        } catch {
            restoreErrors.append("\(window.title): \(error.localizedDescription)")
        }
    }
    do {
        try await verifyFixtureFrames(originals, windows: windows, access: access, stage: "Restore")
    } catch {
        restoreErrors.append(error.localizedDescription)
    }
    if restoreErrors.isEmpty {
        report.append("PASS: Original fixture positions and sizes restored.")
    } else {
        report.append("FAIL: Fixture restoration: \(restoreErrors.joined(separator: "; "))")
    }
    report.append(operationFailure == nil && restoreErrors.isEmpty
        ? "RESULT: PASS. No non-fixture windows were changed."
        : "RESULT: FAIL. No non-fixture windows were changed.")
    return report.joined(separator: "\n")
}

private func fixtureFramesMatch(_ actual: CGRect, _ expected: CGRect) -> Bool {
    abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2
        && abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
}

private func verifyFixtureFrames(
    _ expected: [CGRect], windows: [ManagedWindow], access: WindowAccess, stage: String
) async throws {
    guard expected.count == windows.count else {
        throw IntegrationCheckFailure(detail: "\(stage): Expected-frame count does not match the selected window count.")
    }
    var mismatches: [String] = []
    // Give normal AppKit delivery a short, bounded settling interval. This is
    // asynchronous, so the test runner's AppKit event loop stays responsive.
    for attempt in 0..<8 {
        mismatches = []
        for (window, frame) in zip(windows, expected) {
            guard let actual = await access.readFrame(window) else {
                mismatches.append("\(window.title) is unavailable")
                continue
            }
            if !fixtureFramesMatch(actual, frame) {
                mismatches.append("\(window.title): wanted \(frame), got \(actual)")
            }
        }
        if mismatches.isEmpty { return }
        if attempt < 7 { try await Task.sleep(nanoseconds: 25_000_000) }
    }
    throw IntegrationCheckFailure(detail: "\(stage): \(mismatches.joined(separator: "; "))")
}
