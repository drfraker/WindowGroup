import AppKit

private final class HandlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenNone]
    }
}

@MainActor
final class GroupFrame {
    unowned let controller: GroupController
    private let top = HandlePanel()
    private let left = HandlePanel()
    private let right = HandlePanel()
    private let bottom = HandlePanel()
    private let grip = HandlePanel()
    private let title = NSTextField(labelWithString: "WindowGroup  ·  3 × 2")
    private var visible = false

    init(controller: GroupController) {
        self.controller = controller
        let topView = InteractionView(controller: controller, kind: .move)
        topView.fill = NSColor.controlAccentColor.withAlphaComponent(0.96)
        topView.cornerRadius = 8
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.isSelectable = false
        title.translatesAutoresizingMaskIntoConstraints = false
        topView.addSubview(title)
        let restore = toolbarButton("Restore", action: #selector(restoreWindows))
        restore.toolTip = "Ungroup and restore each window to its original position"
        let release = toolbarButton("Release", action: #selector(releaseWindows))
        release.toolTip = "Ungroup and leave every window where it is"
        topView.addSubview(restore)
        topView.addSubview(release)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: topView.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: topView.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: restore.leadingAnchor, constant: -12),
            release.trailingAnchor.constraint(equalTo: topView.trailingAnchor, constant: -8),
            release.centerYAnchor.constraint(equalTo: topView.centerYAnchor),
            restore.trailingAnchor.constraint(equalTo: release.leadingAnchor, constant: -6),
            restore.centerYAnchor.constraint(equalTo: topView.centerYAnchor)
        ])
        top.contentView = topView
        for panel in [left, right, bottom] {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            panel.contentView = view
            panel.ignoresMouseEvents = true
        }
        let gripView = InteractionView(controller: controller, kind: .resize)
        gripView.fill = .controlAccentColor
        gripView.cornerRadius = 7
        grip.contentView = gripView
        gripView.toolTip = "Drag to resize all grouped windows"
        topView.toolTip = "Drag this bar to move all grouped windows"
    }

    private func toolbarButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    func update(bounds: CGRect) {
        let rect = GroupController.cocoaRect(bounds)
        top.setFrame(CGRect(x: rect.minX - 4, y: rect.maxY + 3, width: rect.width + 8, height: 32), display: true)
        left.setFrame(CGRect(x: rect.minX - 4, y: rect.minY - 4, width: 2, height: rect.height + 6), display: true)
        right.setFrame(CGRect(x: rect.maxX + 2, y: rect.minY - 4, width: 2, height: rect.height + 6), display: true)
        bottom.setFrame(CGRect(x: rect.minX - 4, y: rect.minY - 4, width: rect.width + 8, height: 2), display: true)
        grip.setFrame(CGRect(x: rect.maxX - 12, y: rect.minY - 12, width: 24, height: 24), display: true)
    }

    func show(bounds: CGRect) {
        title.stringValue = "WindowGroup  ·  \(controller.layout.label)  ·  \(controller.members.count) windows"
        update(bounds: bounds)
        visible = true
        for panel in [left, right, bottom, top, grip] { panel.orderFrontRegardless() }
    }

    func hide() {
        visible = false
        for panel in [top, left, right, bottom, grip] { panel.orderOut(nil) }
    }

    func setHint(_ hint: String) {
        title.stringValue = "WindowGroup  ·  Size limit reached"
        title.toolTip = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.title.stringValue = "WindowGroup  ·  \(self.controller.layout.label)  ·  \(self.controller.members.count) windows"
        }
    }

    @objc private func restoreWindows() { Task { await controller.release(restore: true) } }
    @objc private func releaseWindows() { Task { await controller.release(restore: false) } }
}

@MainActor
private final class InteractionView: NSView {
    enum Kind { case move, resize }
    unowned let controller: GroupController
    let kind: Kind
    var fill = NSColor.controlAccentColor
    var cornerRadius: CGFloat = 0
    private var startMouse = CGPoint.zero
    private var startBounds = CGRect.zero

    init(controller: GroupController, kind: Kind) {
        self.controller = controller
        self.kind = kind
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: kind == .move ? .openHand : .crosshair)
    }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        if kind == .resize {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: 7, y: 8))
            path.line(to: NSPoint(x: 16, y: 17))
            path.move(to: NSPoint(x: 12, y: 8))
            path.line(to: NSPoint(x: 16, y: 12))
            path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startBounds = controller.bounds
        controller.beginInteraction()
        if kind == .move { NSCursor.closedHand.push() }
    }
    override func mouseDragged(with event: NSEvent) { updateDrag() }
    override func mouseUp(with event: NSEvent) {
        updateDrag()
        if kind == .move { NSCursor.pop() }
    }
    private func updateDrag() {
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - startMouse.x, y: startMouse.y - mouse.y)
        if kind == .move { controller.move(from: startBounds, delta: delta) }
        else { controller.resize(from: startBounds, delta: delta) }
    }
}
