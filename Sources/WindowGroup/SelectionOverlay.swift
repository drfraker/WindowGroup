import AppKit
import WindowGroupCore

/// Temporary, app-owned selection UI. It never moves or resizes the windows
/// being selected, and does not install an event tap or a global mouse monitor.
@MainActor
final class SelectionOverlay {
    var onConfirm: (([ManagedWindow], NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isActive = false

    private let selectionLimit = 12
    private var windows: [ManagedWindow] = []
    private var frames: [CGRect] = []
    private var selectedIDs: [UUID] = []
    private var panels: [SelectionPanel] = []
    private var observers: [NSObjectProtocol] = []
    private var previousApplication: NSRunningApplication?
    private var targetScreen: NSScreen?
    private var dragStart: CGPoint?
    private var dragBase: [UUID] = []
    private var additiveDrag = false
    private var didDrag = false
    private var marquee: CGRect?
    private var limitReached = false
    private var loading = false
    private let debugReportURL: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--selection-debug-report"),
              arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()

    init() {}

    func begin(windows: [ManagedWindow], initiallySelected: [UUID] = []) {
        startSession(windows: windows, initiallySelected: initiallySelected, loading: false)
    }

    /// Covers the desktop before Accessibility enumeration starts so the
    /// initiating gesture cannot accidentally reach an ordinary app window.
    func beginLoading() {
        startSession(windows: [], initiallySelected: [], loading: true)
    }

    /// Populates the already-visible panels without reactivating the app or
    /// replacing their input capture. A cancelled session stays cancelled.
    func completeLoading(windows: [ManagedWindow]) {
        guard isActive, loading else { return }
        prepareCandidates(windows, initiallySelected: [])
        loading = false
        updateViews()
    }

    private func prepareCandidates(_ windows: [ManagedWindow], initiallySelected: [UUID]) {
        self.windows = windows.enumerated().sorted {
            if $0.element.stackingOrder == $1.element.stackingOrder { return $0.offset < $1.offset }
            return $0.element.stackingOrder < $1.element.stackingOrder
        }.map(\.element)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        frames = self.windows.map {
            CGRect(x: $0.originalFrame.minX, y: desktopTop - $0.originalFrame.maxY,
                   width: $0.originalFrame.width, height: $0.originalFrame.height)
        }
        let eligible = Set(self.windows.map(\.id))
        var seen = Set<UUID>()
        selectedIDs = initiallySelected.filter { eligible.contains($0) && seen.insert($0).inserted }
        limitReached = selectedIDs.count > selectionLimit
        selectedIDs = Array(selectedIDs.prefix(selectionLimit))
        debug("candidates", ["frames": frames.map(rectValues), "selectedCount": selectedIDs.count])
    }

    private func startSession(windows: [ManagedWindow], initiallySelected: [UUID], loading: Bool) {
        if isActive { dismiss() }
        previousApplication = NSWorkspace.shared.frontmostApplication
        self.loading = loading
        debug("begin", ["screens": NSScreen.screens.map { rectValues($0.frame) }, "loading": loading])
        prepareCandidates(windows, initiallySelected: initiallySelected)
        dragStart = nil
        marquee = nil
        targetScreen = screen(at: NSEvent.mouseLocation) ?? NSScreen.screens.first
        guard let targetScreen else {
            clearSelectionState()
            onCancel?()
            return
        }

        isActive = true
        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen)
            panel.selectionOwner = self
            panel.contentView = SelectionCanvas(owner: self, screen: screen)
            panels.append(panel)
        }
        installObservers()
        NSApp.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        if let keyPanel = panels.first(where: { $0.selectionScreen == targetScreen }) {
            keyPanel.makeKeyAndOrderFront(nil)
            keyPanel.makeFirstResponder(keyPanel.contentView)
        }
        updateViews()
    }

    func cancel() {
        cancel(restoringFocus: true)
    }

    private func cancel(restoringFocus: Bool) {
        guard isActive else { return }
        let previous = previousApplication
        dismiss()
        if restoringFocus, let previous, !previous.isTerminated,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate(options: [])
        }
        onCancel?()
    }

    fileprivate func confirm(on screen: NSScreen? = nil) {
        guard !loading else { return }
        guard isActive, !selectedIDs.isEmpty,
              let destination = screen ?? targetScreen ?? NSScreen.screens.first else {
            NSSound.beep()
            return
        }
        let chosen = selectedIDs.compactMap { id in windows.first { $0.id == id } }
        guard !chosen.isEmpty else { return }
        dismiss()
        onConfirm?(chosen, destination)
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            cancel()
            return true
        case 36, 76:
            confirm(on: screen(at: NSEvent.mouseLocation) ?? targetScreen)
            return true
        default:
            return false
        }
    }

    fileprivate func gestureBegan(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        debug("gestureBegan", ["point": pointValues(point), "selectedCount": selectedIDs.count,
                               "loading": loading, "active": isActive])
        guard isActive, !loading else { return }
        dragStart = point
        dragBase = selectedIDs
        additiveDrag = modifiers.contains(.command)
        didDrag = false
        marquee = nil
        limitReached = false
        targetScreen = screen(at: point) ?? targetScreen
    }

    fileprivate func gestureChanged(to point: CGPoint) {
        debug("gestureChanged", ["point": pointValues(point), "selectedCount": selectedIDs.count,
                                 "loading": loading, "hasStart": dragStart != nil])
        guard isActive, !loading, let start = dragStart else { return }
        if !didDrag && hypot(point.x - start.x, point.y - start.y) < 3 { return }
        didDrag = true
        let rectangle = SelectionGeometry.marquee(start, point)
        marquee = rectangle
        let matches = SelectionGeometry.selectedIndices(frames: frames, marquee: rectangle)
            .sorted {
                let first = windows[$0].originalFrame
                let second = windows[$1].originalFrame
                if first.minY != second.minY { return first.minY < second.minY }
                if first.minX != second.minX { return first.minX < second.minX }
                return $0 < $1
            }
            .map { windows[$0].id }
        setSelection(additiveDrag ? adding(matches, to: dragBase) : matches)
        debug("marqueeSelection", ["point": pointValues(point), "marquee": rectValues(rectangle),
                                   "matchedCount": matches.count, "selectedCount": selectedIDs.count])
        targetScreen = screen(at: point) ?? targetScreen
        updateViews()
    }

    fileprivate func gestureEnded(at point: CGPoint) {
        debug("gestureEnded", ["point": pointValues(point), "selectedCount": selectedIDs.count,
                               "loading": loading, "hasStart": dragStart != nil])
        guard isActive, !loading, dragStart != nil else { return }
        gestureChanged(to: point)
        if !didDrag {
            let clicked = SelectionGeometry.topmostIndex(at: point, framesFrontToBack: frames)
                .map { windows[$0].id }
            if additiveDrag {
                var next = dragBase
                if let clicked {
                    if let index = next.firstIndex(of: clicked) { next.remove(at: index) }
                    else { next.append(clicked) }
                }
                setSelection(next)
            } else {
                setSelection(clicked.map { [$0] } ?? [])
            }
        }
        targetScreen = screen(at: point) ?? targetScreen
        dragStart = nil
        marquee = nil
        debug("selectionEnded", ["point": pointValues(point), "selectedCount": selectedIDs.count])
        updateViews()
    }

    fileprivate func debugEvent(_ event: NSEvent, global: CGPoint, selectionScreen: NSScreen) {
        var values: [String: Any] = [
            "type": event.type.rawValue,
            "localPoint": pointValues(event.locationInWindow),
            "globalPoint": pointValues(global),
            "selectionScreen": rectValues(selectionScreen.frame)
        ]
        if let eventWindow = event.window { values["eventWindow"] = rectValues(eventWindow.frame) }
        debug("mouseEvent", values)
    }

    private func pointValues(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }
    private func rectValues(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    /// Opt-in geometry-only diagnostics for native interaction testing. Never
    /// writes unless an explicit --selection-debug-report path was supplied.
    private func debug(_ phase: String, _ fields: [String: Any]) {
        guard let url = debugReportURL else { return }
        var record = fields
        record["phase"] = phase
        record["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: [.withoutOverwriting])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    }

    fileprivate func draw(in canvas: SelectionCanvas) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        canvas.bounds.fill()
        let screenOrigin = canvas.selectionScreen.frame.origin
        for index in windows.indices.reversed() {
            let global = frames[index]
            guard global.intersects(canvas.selectionScreen.frame) else { continue }
            let rect = global.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).insetBy(dx: 1.5, dy: 1.5)
            let order = selectedIDs.firstIndex(of: windows[index].id)
            let color = order == nil ? NSColor.white.withAlphaComponent(0.55) : NSColor.controlAccentColor
            if order != nil {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            }
            let outline = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            outline.lineWidth = order == nil ? 1 : 3
            color.setStroke()
            outline.stroke()
            let prefix = order.map { "\($0 + 1)  ·  " } ?? ""
            drawLabel(prefix + windows[index].appName + " — " + windows[index].title,
                      in: rect, selected: order != nil)
            drawCenterMarker(at: CGPoint(x: rect.midX, y: rect.midY), selected: order != nil)
        }
        if let marquee {
            let rect = marquee.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            rect.fill()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }

    private func drawLabel(_ label: String, in rect: CGRect, selected: Bool) {
        guard rect.width >= 42, rect.height >= 26 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let desired = (label as NSString).size(withAttributes: attributes).width + 18
        let labelRect = CGRect(x: rect.minX + 7, y: rect.maxY - 28,
                               width: min(desired, rect.width - 14), height: 22)
        (selected ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(in: labelRect.insetBy(dx: 8, dy: 3), withAttributes: attributes)
    }

    private func drawCenterMarker(at point: CGPoint, selected: Bool) {
        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        NSColor.black.withAlphaComponent(0.72).setFill()
        ring.fill()
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.stroke()
        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        (selected ? NSColor.controlAccentColor : NSColor.white).setFill()
        dot.fill()
    }

    private func setSelection(_ ids: [UUID]) {
        limitReached = ids.count > selectionLimit
        selectedIDs = Array(ids.prefix(selectionLimit))
    }

    private func adding(_ additions: [UUID], to existing: [UUID]) -> [UUID] {
        var seen = Set(existing)
        return existing + additions.filter { seen.insert($0).inserted }
    }

    private func updateViews() {
        let count = selectedIDs.count
        let title: String
        if loading { title = "Finding windows…" }
        else if windows.isEmpty { title = "No eligible windows on this desktop" }
        else if limitReached { title = "\(count) selected · Maximum \(selectionLimit) windows" }
        else { title = "\(count) window\(count == 1 ? "" : "s") selected" }
        for panel in panels {
            guard let canvas = panel.contentView as? SelectionCanvas else { continue }
            canvas.updateHUD(title: title, canContinue: !loading && count > 0,
                             limitReached: limitReached, loading: loading)
            canvas.needsDisplay = true
        }
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.cancel(restoringFocus: false) } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.cancel(restoringFocus: false) } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.cancel(restoringFocus: false) } })
    }

    private func dismiss() {
        isActive = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panels.removeAll()
        clearSelectionState()
        NSCursor.arrow.set()
    }

    private func clearSelectionState() {
        windows = []
        frames = []
        selectedIDs = []
        dragBase = []
        dragStart = nil
        marquee = nil
        targetScreen = nil
        previousApplication = nil
        loading = false
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    let selectionScreen: NSScreen
    weak var selectionOwner: SelectionOverlay?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        selectionScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Select windows — \(screen.localizedName)"
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.transient, .fullScreenNone]
        setAccessibilityLabel("Select windows for WindowGroup")
    }

    override func keyDown(with event: NSEvent) {
        if selectionOwner?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { selectionOwner?.cancel() }
}

@MainActor
fileprivate final class SelectionCanvas: NSView {
    weak var owner: SelectionOverlay?
    let selectionScreen: NSScreen
    private let titleLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(wrappingLabelWithString: "")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    override var acceptsFirstResponder: Bool { true }

    init(owner: SelectionOverlay, screen: NSScreen) {
        self.owner = owner
        selectionScreen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        let hud = NSVisualEffectView()
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 12
        hud.layer?.masksToBounds = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        instructionLabel.font = .systemFont(ofSize: 11)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.alignment = .center
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded
        continueButton.target = self
        continueButton.action = #selector(continueSelection)
        continueButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [titleLabel, instructionLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(stack)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            hud.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: hud.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) { owner?.draw(in: self) }
    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { owner?.cancel() }
    override func mouseDown(with event: NSEvent) {
        let point = screenPoint(for: event)
        owner?.debugEvent(event, global: point, selectionScreen: selectionScreen)
        owner?.gestureBegan(at: point, modifiers: event.modifierFlags)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = screenPoint(for: event)
        owner?.debugEvent(event, global: point, selectionScreen: selectionScreen)
        owner?.gestureChanged(to: point)
    }
    override func mouseUp(with event: NSEvent) {
        let point = screenPoint(for: event)
        owner?.debugEvent(event, global: point, selectionScreen: selectionScreen)
        owner?.gestureEnded(at: point)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        // Use the event's own position: queued or targeted native events need
        // not coincide with the physical cursor's position when delivered.
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    func updateHUD(title: String, canContinue: Bool, limitReached: Bool, loading: Bool) {
        titleLabel.stringValue = title
        titleLabel.textColor = limitReached ? .systemOrange : .labelColor
        instructionLabel.stringValue = loading ? "Esc cancels" :
            "Drag across window centers to select · ⌘-drag adds · ⌘-click toggles\nReturn continues · Esc cancels"
        continueButton.isEnabled = canContinue
        setAccessibilityLabel(loading ? title + " Esc cancels." :
            title + ". Drag to select windows. Command-click toggles a window.")
    }

    @objc private func continueSelection() { owner?.confirm(on: selectionScreen) }
    @objc private func cancelSelection() { owner?.cancel() }
}
