import AppKit
import ApplicationServices
import WindowGroupCore

@MainActor
final class GroupController {
    let access = WindowAccess()
    static let maximumSelection = 12
    private(set) var layout = GridLayout(columns: 3, rows: 2)
    var grid: GridGeometry { GridGeometry(columns: layout.columns, rows: layout.rows, gap: 8) }
    var availableLayouts: [GridLayout] { GridLayout.suggested(for: selected.count) }
    var windows: [ManagedWindow] = []
    var selected: [UUID] = []
    var status = "Select up to 12 windows, then choose a grid."
    var busy = false
    var trusted = WindowAccess.isTrusted
    var onChange: (() -> Void)?
    var onGroupCreated: (() -> Void)?
    var onPickWindows: (() -> Void)?
    private(set) var members: [ManagedWindow] = []
    private(set) var bounds = CGRect.zero
    private(set) var screenBounds = CGRect.zero
    private var originals: [CGRect] = []
    private var lastFrames: [CGRect] = []
    private var minimumCell = CGSize(width: 180, height: 120)
    private var pendingBounds: CGRect?
    private var applying = false
    private var ending = false
    private var generation = 0
    private var spaceSuspended = false
    private var healthCheckRunning = false
    private var desktopSelectionActive = false
    private var desktopEpoch = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    lazy var frame = GroupFrame(controller: self)

    var hasGroup: Bool { !members.isEmpty }
    var minimumSize: CGSize { grid.minimumBoundsSize(cellMinimum: minimumCell) }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.applicationActivated(app.processIdentifier) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.spaceSuspended = true
                self?.desktopEpoch += 1
                self?.pendingBounds = nil
                self?.frame.hide()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.desktopEpoch += 1
                guard self.hasGroup else { self.onChange?(); return }
                await self.release(restore: false)
                self.status = "Display configuration changed. The group was released; select the windows again."
                self.onChange?()
                self.onPickWindows?()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.healthCheck() }
        }
    }

    static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func axRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func cocoaRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }

    func refresh() {
        guard !busy else { return }
        trusted = WindowAccess.isTrusted
        guard trusted else {
            status = "Allow WindowGroup in Accessibility so it can list, move, and resize your windows."
            onChange?()
            return
        }
        busy = true
        status = "Finding resizable windows on your current desktop…"
        onChange?()
        Task {
            let previous = selected.compactMap { id in windows.first { $0.id == id } }
            let found = await access.listWindows()
            windows = found
            selected = previous.compactMap { old in found.first { CFEqual($0.element, old.element) }?.id }
            busy = false
            updateLayoutForSelection()
            status = found.isEmpty ? "No eligible windows found. Open ordinary, unminimized windows on this desktop, then refresh." : "Select up to 12 windows in the order you want them, left to right."
            onChange?()
        }
    }

    func toggle(_ window: ManagedWindow) {
        guard !busy, !hasGroup else { return }
        if let index = selected.firstIndex(of: window.id) {
            selected.remove(at: index)
        } else if selected.count < Self.maximumSelection {
            selected.append(window.id)
        } else {
            NSSound.beep()
            status = "12 selected. Deselect one before adding another."
        }
        updateLayoutForSelection()
        onChange?()
    }

    func adoptDesktopSelection(_ selection: [ManagedWindow], from candidates: [ManagedWindow]) {
        guard !busy, !hasGroup else { return }
        windows = candidates
        selected = Array(selection.prefix(Self.maximumSelection)).map(\.id)
        layout = availableLayouts.first ?? GridLayout(columns: 3, rows: 2)
        status = "\(selected.count) windows selected. Choose a grid and click Arrange."
        onChange?()
    }

    func chooseLayout(_ choice: GridLayout) {
        guard !busy, !hasGroup, availableLayouts.contains(choice) else { return }
        layout = choice
        onChange?()
    }

    private func updateLayoutForSelection() {
        let choices = availableLayouts
        if !choices.contains(layout), let first = choices.first { layout = first }
    }

    func setDesktopSelectionActive(_ active: Bool) {
        desktopSelectionActive = active
        if active { frame.hide() }
        else if hasGroup && !spaceSuspended && !ending {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if members.contains(where: { $0.pid == frontPID }) { frame.show(bounds: bounds) }
        }
    }

    func createGroup(on screen: NSScreen) {
        guard !busy, !hasGroup, (1...Self.maximumSelection).contains(selected.count), layout.capacity >= selected.count, WindowAccess.isTrusted else { return }
        let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard NSScreen.screens.contains(where: { ($0.deviceDescription[displayKey] as? NSNumber) == (screen.deviceDescription[displayKey] as? NSNumber) }) else {
            status = "That display is no longer connected. Choose a current display."
            onChange?()
            return
        }
        let chosen = selected.compactMap { id in windows.first { $0.id == id } }
        guard chosen.count == selected.count else { return }
        busy = true
        status = "Arranging \(chosen.count) windows in a \(layout.label) grid…"
        onChange?()
        let expectedDesktop = desktopEpoch
        Task {
            var captured: [CGRect] = []
            for window in chosen {
                guard let current = await access.readFrame(window) else {
                    busy = false
                    status = "A selected window closed or stopped responding. Refresh and select again."
                    onChange?()
                    return
                }
                captured.append(current)
            }
            guard desktopEpoch == expectedDesktop,
                  NSScreen.screens.contains(where: { ($0.deviceDescription[displayKey] as? NSNumber) == (screen.deviceDescription[displayKey] as? NSNumber) }) else {
                busy = false
                status = "Your desktop or display changed before arrangement. No windows were moved; try again on this desktop."
                onChange?()
                return
            }
            let visible = Self.axRect(screen.visibleFrame)
            // Leave room for the group's bar and handles inside the usable display.
            screenBounds = CGRect(x: visible.minX + 14, y: visible.minY + 48,
                                  width: visible.width - 28, height: visible.height - 64)
            let minimum = grid.minimumBoundsSize(cellMinimum: CGSize(width: 180, height: 120))
            guard screenBounds.width >= minimum.width, screenBounds.height >= minimum.height else {
                busy = false
                status = "This display is too small for that grid. Choose another layout or a larger display."
                onChange?()
                return
            }
            minimumCell = CGSize(width: 180, height: 120)
            members = chosen
            generation += 1
            let operationGeneration = generation
            applying = true
            spaceSuspended = false
            originals = captured
            lastFrames = captured
            // Keep a newly grouped set near its existing location and scale.
            // A very wide monitor should not turn small windows into huge ones.
            let naturalCell = CGSize(width: captured.map(\.width).max() ?? 420,
                                     height: captured.map(\.height).max() ?? 280)
            let naturalSize = grid.minimumBoundsSize(cellMinimum: naturalCell)
            let origin = CGPoint(x: captured.map(\.minX).min() ?? screenBounds.minX,
                                 y: captured.map(\.minY).min() ?? screenBounds.minY)
            bounds = grid.clamp(bounds: CGRect(origin: origin, size: naturalSize),
                                to: screenBounds, minimumSize: minimumSize).integral
            var target = bounds
            do {
                for member in members {
                    guard desktopEpoch == expectedDesktop && !ending else { throw GroupError.desktopChanged }
                    await access.raise(member)
                }
                let measured: [CGRect]
                do {
                    measured = try await apply(target, expectedDesktop: expectedDesktop)
                } catch GroupError.minimum(_) {
                    // A smaller starting grid leaves room to drag. If an app
                    // needs that spare room, try the full usable group area.
                    target = screenBounds
                    measured = try await apply(target, expectedDesktop: expectedDesktop)
                }
                lastFrames = measured
                bounds = target
                busy = false
                status = "Group active. Drag its top bar to move; drag the lower-right handle to resize."
                if generation == operationGeneration && !ending && !spaceSuspended {
                    frame.show(bounds: bounds)
                    onGroupCreated?()
                }
            } catch {
                let failures = await restoreFrames(captured, for: chosen)
                members = []
                originals = []
                lastFrames = []
                busy = false
                status = error.localizedDescription + (failures == 0 ? " Original positions restored." : " Some windows could not be restored; check their positions.")
            }
            applying = false
            onChange?()
        }
    }

    private enum GroupError: LocalizedError {
        case minimum(String)
        case refused(String)
        case desktopChanged
        var errorDescription: String? {
            switch self {
            case .minimum(let app): return "\(app) needs a larger window. The grid cannot shrink further."
            case .refused(let app): return "\(app) did not accept its grid position."
            case .desktopChanged: return "The desktop changed during arrangement."
            }
        }
    }

    private func apply(_ target: CGRect, expectedDesktop: Int? = nil) async throws -> [CGRect] {
        let expected = expectedDesktop ?? desktopEpoch
        let desired = grid.frames(in: target)
        var measured: [CGRect] = []
        for (index, member) in members.enumerated() {
            guard desktopEpoch == expected else { throw GroupError.desktopChanged }
            let actual = try await access.applyFrame(desired[index], to: member)
            guard desktopEpoch == expected else { throw GroupError.desktopChanged }
            let expected = desired[index]
            if actual.width > expected.width + 3 || actual.height > expected.height + 3 {
                if actual.width > expected.width + 3 { minimumCell.width = max(minimumCell.width, actual.width) }
                if actual.height > expected.height + 3 { minimumCell.height = max(minimumCell.height, actual.height) }
                throw GroupError.minimum(member.appName)
            }
            guard abs(actual.minX - expected.minX) <= 3, abs(actual.minY - expected.minY) <= 3,
                  abs(actual.width - expected.width) <= 3, abs(actual.height - expected.height) <= 3 else {
                throw GroupError.refused(member.appName)
            }
            measured.append(actual)
        }
        return measured
    }

    func beginInteraction() {
        guard hasGroup, !ending, !spaceSuspended else { return }
        // Raising is explicit here so an unrelated app is never moved or hidden.
        let token = generation
        Task {
            for member in members {
                guard token == generation && !ending && !spaceSuspended else { return }
                await access.raise(member)
            }
        }
    }

    func move(from original: CGRect, delta: CGPoint) {
        enqueue(grid.move(original: original, delta: delta, in: screenBounds))
    }

    func resize(from original: CGRect, delta: CGPoint) {
        enqueue(grid.resize(original: original, delta: delta, minimumSize: minimumSize, in: screenBounds))
    }

    private func enqueue(_ proposed: CGRect) {
        guard hasGroup, !ending, !spaceSuspended else { return }
        let target = grid.clamp(bounds: proposed, to: screenBounds, minimumSize: minimumSize)
        guard target.width <= screenBounds.width + 1, target.height <= screenBounds.height + 1 else { return }
        pendingBounds = target
        // Render the handles immediately; IPC is serialized and intermediate requests coalesced.
        frame.update(bounds: target)
        guard !applying else { return }
        applying = true
        Task {
            while let next = pendingBounds, hasGroup {
                pendingBounds = nil
                do {
                    let accepted = try await apply(next)
                    lastFrames = accepted
                    bounds = next
                    if pendingBounds == nil { frame.update(bounds: bounds) }
                } catch {
                    pendingBounds = nil
                    let failures = await restoreFrames(lastFrames, for: members)
                    frame.update(bounds: bounds)
                    status = error.localizedDescription
                    if failures > 0 {
                        status += " A window could not be restored. The group has been released."
                        members = []
                        originals = []
                        lastFrames = []
                        frame.hide()
                    }
                    frame.setHint(status)
                    onChange?()
                    break
                }
            }
            applying = false
        }
    }

    func showGroup() {
        guard hasGroup, !ending else { return }
        let token = generation
        Task {
            if spaceSuspended {
                let visible = await access.listWindows()
                guard token == generation && !ending else { return }
                guard members.allSatisfy({ member in visible.contains { CFEqual($0.element, member.element) } }) else {
                    status = "Return to the desktop containing all grouped windows, then choose Show Group."
                    onChange?()
                    onPickWindows?()
                    return
                }
                spaceSuspended = false
            }
            for member in members {
                guard token == generation && !ending && !spaceSuspended else { return }
                await access.raise(member)
            }
            guard token == generation && hasGroup && !ending && !spaceSuspended else { return }
            frame.show(bounds: bounds)
            onGroupCreated?()
        }
    }

    func release(restore: Bool) async {
        if ending {
            while ending { try? await Task.sleep(nanoseconds: 20_000_000) }
            return
        }
        guard hasGroup else { return }
        ending = true
        generation += 1
        pendingBounds = nil
        frame.hide()
        while applying { try? await Task.sleep(nanoseconds: 20_000_000) }
        let failures = restore ? await restoreFrames(originals, for: members) : 0
        members = []
        originals = []
        lastFrames = []
        selected = []
        ending = false
        spaceSuspended = false
        status = restore ? (failures == 0 ? "Original window positions restored." : "Some windows no longer respond and could not be restored.") : "Group released. Your windows stay where they are."
        onChange?()
    }

    private func restoreFrames(_ frames: [CGRect], for windows: [ManagedWindow]) async -> Int {
        var failures = 0
        for (window, old) in zip(windows, frames) {
            do {
                let actual = try await access.applyFrame(old, to: window)
                if abs(actual.minX - old.minX) > 4 || abs(actual.minY - old.minY) > 4 || abs(actual.width - old.width) > 4 || abs(actual.height - old.height) > 4 { failures += 1 }
            } catch { failures += 1 }
        }
        return failures
    }

    private func applicationActivated(_ pid: pid_t) {
        if hasGroup && !ending && !busy && !spaceSuspended && !desktopSelectionActive {
            if members.contains(where: { $0.pid == pid }) || pid == ProcessInfo.processInfo.processIdentifier {
                frame.show(bounds: bounds)
            } else {
                frame.hide()
            }
        }
        if !trusted && WindowAccess.isTrusted { refresh() }
    }

    private func healthCheck() async {
        let nowTrusted = WindowAccess.isTrusted
        if nowTrusted != trusted {
            trusted = nowTrusted
            if nowTrusted { refresh() }
            else {
                await release(restore: false)
                status = "Accessibility access was removed. Enable it again to manage windows."
                onChange?()
            }
        }
        guard hasGroup, !applying, !busy, !ending, !healthCheckRunning else { return }
        healthCheckRunning = true
        defer { healthCheckRunning = false }
        for member in members {
            if !(await access.isAlive(member)) {
                await release(restore: false)
                status = "A grouped window closed or became unavailable. The other windows were released in place."
                onChange?()
                return
            }
        }
    }
}
