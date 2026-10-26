import AppKit
import WindowGroupCore

@MainActor
final class WindowPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let controller: GroupController
    var onStartDesktopSelection: (() -> Void)?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "0 selected")
    private let arrange = NSButton(title: "Arrange Windows", target: nil, action: nil)
    private let desktopSelect = NSButton(title: "Select on Desktop   ⌃⌥G", target: nil, action: nil)
    private let gestureHelp = NSTextField(labelWithString: "Drag a selection box or ⌘-click windows")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let permissionButton = NSButton(title: "Allow Accessibility…", target: nil, action: nil)
    private let displays = NSPopUpButton()
    private let layouts = NSPopUpButton()
    private let preview = GridPreview()
    private let releaseButton = NSButton(title: "Release Group", target: nil, action: nil)
    private var filtered: [ManagedWindow] = []
    private var knownScreens: [NSScreen] = []

    init(controller: GroupController) {
        self.controller = controller
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 730, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WindowGroup"
        window.subtitle = "Select. Arrange. Move together."
        window.minSize = CGSize(width: 650, height: 690)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        controller.onChange = { [weak self] in self?.reload() }
        controller.onGroupCreated = { [weak self] in self?.window?.orderOut(nil) }
        controller.onPickWindows = { [weak self] in self?.present() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Bring your windows together")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let description = NSTextField(wrappingLabelWithString: "Select windows on your desktop or in this list. Choose a grid, then move and resize the whole group from its shared frame.")
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 90).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let heading = NSStackView(views: [title, description])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8
        let header = NSStackView(views: [heading, preview])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 24

        desktopSelect.target = self
        desktopSelect.action = #selector(selectOnDesktop)
        desktopSelect.bezelStyle = .rounded
        gestureHelp.textColor = .secondaryLabelColor
        gestureHelp.font = .systemFont(ofSize: 12)
        let selectionRow = NSStackView(views: [desktopSelect, gestureHelp, NSView()])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 14

        search.placeholderString = "Filter by app or window title"
        search.delegate = self
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        let searchRow = NSStackView(views: [search, refreshButton])
        searchRow.orientation = .horizontal
        searchRow.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let selectColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("select"))
        selectColumn.width = 34
        selectColumn.minWidth = 34
        selectColumn.maxWidth = 34
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.width = 560
        table.addTableColumn(selectColumn)
        table.addTableColumn(titleColumn)
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 4, height: 4)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .controlBackgroundColor
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Available windows")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let orderLabel = NSTextField(labelWithString: "Selection order → left to right, top to bottom")
        orderLabel.font = .systemFont(ofSize: 11)
        orderLabel.textColor = .secondaryLabelColor
        let countRow = NSStackView(views: [countLabel, NSView(), orderLabel])
        countRow.orientation = .horizontal

        let displayLabel = NSTextField(labelWithString: "Arrange on")
        knownScreens = NSScreen.screens
        for (index, screen) in knownScreens.enumerated() {
            displays.addItem(withTitle: "\(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
            displays.lastItem?.tag = index
        }
        displays.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let displayRow = NSStackView(views: [displayLabel, displays])
        displayRow.orientation = .horizontal
        displayRow.spacing = 12

        let layoutLabel = NSTextField(labelWithString: "Grid")
        layouts.target = self
        layouts.action = #selector(layoutChanged)
        layouts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let gridRow = NSStackView(views: [layoutLabel, layouts])
        gridRow.orientation = .horizontal
        gridRow.spacing = 12

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded
        arrange.target = self
        arrange.action = #selector(arrangeSelected)
        arrange.bezelStyle = .rounded
        arrange.keyEquivalent = "\r"
        arrange.contentTintColor = .controlAccentColor
        releaseButton.target = self
        releaseButton.action = #selector(releaseGroup)
        releaseButton.bezelStyle = .rounded
        let footer = NSStackView(views: [permissionButton, releaseButton, NSView(), arrange])
        footer.orientation = .horizontal
        footer.spacing = 10
        let stack = NSStackView(views: [header, selectionRow, searchRow, scroll, countRow, displayRow, gridRow, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
    }

    func present(refresh: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refresh && !controller.hasGroup { controller.refresh() }
    }

    func preferDisplay(_ screen: NSScreen) {
        reloadDisplays()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let index = knownScreens.firstIndex(where: { ($0.deviceDescription[key] as? NSNumber) == (screen.deviceDescription[key] as? NSNumber) }) {
            displays.selectItem(at: index)
        }
    }

    func setShortcutAvailable(_ available: Bool) {
        desktopSelect.title = available ? "Select on Desktop   ⌃⌥G" : "Select on Desktop"
        gestureHelp.stringValue = available ? "Drag a selection box or ⌘-click windows" : "Shortcut is in use. Use this button instead."
    }

    func reload() {
        reloadDisplays()
        let filter = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = controller.windows.filter { filter.isEmpty || $0.appName.localizedCaseInsensitiveContains(filter) || $0.title.localizedCaseInsensitiveContains(filter) }
        table.reloadData()
        countLabel.stringValue = "\(controller.selected.count) selected · up to 12"
        preview.count = controller.selected.count
        preview.layout = controller.layout
        preview.needsDisplay = true
        layouts.removeAllItems()
        for (index, choice) in controller.availableLayouts.enumerated() {
            let empty = choice.capacity - controller.selected.count
            let suffix = empty > 0 ? " — \(empty) empty \(empty == 1 ? "slot" : "slots")" : ""
            layouts.addItem(withTitle: choice.label + suffix)
            layouts.lastItem?.tag = index
            if choice == controller.layout { layouts.selectItem(at: index) }
        }
        if controller.selected.isEmpty { layouts.addItem(withTitle: "Select windows to see layouts") }
        statusLabel.stringValue = controller.status
        statusLabel.setAccessibilityValue(controller.status)
        arrange.isEnabled = controller.trusted && !controller.busy && (controller.hasGroup || !controller.selected.isEmpty)
        arrange.title = controller.hasGroup ? "Show Group" : (controller.selected.isEmpty ? "Arrange Windows" : "Arrange \(controller.selected.count) \(controller.selected.count == 1 ? "Window" : "Windows")")
        desktopSelect.isEnabled = controller.trusted && !controller.busy
        layouts.isEnabled = !controller.hasGroup && !controller.busy && !controller.selected.isEmpty
        refreshButton.isEnabled = !controller.busy && !controller.hasGroup
        permissionButton.isHidden = controller.trusted
        releaseButton.isHidden = !controller.hasGroup
        search.isEnabled = !controller.hasGroup
        displays.isEnabled = !controller.hasGroup && !controller.busy
    }

    private func reloadDisplays() {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let oldID: NSNumber? = knownScreens.indices.contains(displays.indexOfSelectedItem)
            ? knownScreens[displays.indexOfSelectedItem].deviceDescription[key] as? NSNumber : nil
        let screens = NSScreen.screens
        let oldIDs = knownScreens.compactMap { $0.deviceDescription[key] as? NSNumber }
        let newIDs = screens.compactMap { $0.deviceDescription[key] as? NSNumber }
        guard oldIDs != newIDs || knownScreens.map(\.frame) != screens.map(\.frame) else { return }
        knownScreens = screens
        displays.removeAllItems()
        for (index, screen) in screens.enumerated() {
            displays.addItem(withTitle: "\(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
            displays.lastItem?.tag = index
            if screen.deviceDescription[key] as? NSNumber == oldID { displays.selectItem(at: index) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row]
        if tableColumn?.identifier.rawValue == "select" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheckbox(_:)))
            button.tag = row
            button.state = controller.selected.contains(item.id) ? .on : .off
            button.isEnabled = !controller.busy && !controller.hasGroup
            button.setAccessibilityLabel("Select \(item.appName), \(item.title)")
            let cell = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: cell.centerXAnchor), button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let app = NSTextField(labelWithString: item.appName)
        app.font = .systemFont(ofSize: 11)
        app.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, app])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let icon = NSImageView()
        icon.image = NSRunningApplication(processIdentifier: item.pid)?.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let order = controller.selected.firstIndex(of: item.id).map { "\($0 + 1)" } ?? ""
        let badge = NSTextField(labelWithString: order)
        badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        badge.textColor = .controlAccentColor
        badge.alignment = .right
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let line = NSStackView(views: [icon, labels, NSView(), badge])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 10)
        line.toolTip = "\(item.appName) — \(item.title)"
        return line
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func toggleCheckbox(_ sender: NSButton) {
        guard filtered.indices.contains(sender.tag) else { return }
        controller.toggle(filtered[sender.tag])
    }
    @objc private func rowClicked() {
        let row = table.clickedRow
        guard table.clickedColumn != 0, filtered.indices.contains(row) else { return }
        controller.toggle(filtered[row])
    }
    @objc private func refresh() { controller.refresh() }
    @objc private func selectOnDesktop() { onStartDesktopSelection?() }
    @objc private func layoutChanged() {
        guard let index = layouts.selectedItem?.tag, controller.availableLayouts.indices.contains(index) else { return }
        controller.chooseLayout(controller.availableLayouts[index])
    }
    @objc private func requestPermission() {
        WindowAccess.requestAccess()
        WindowAccess.openAccessibilitySettings()
    }
    @objc private func arrangeSelected() {
        if controller.hasGroup { controller.showGroup(); return }
        guard let index = displays.selectedItem?.tag, knownScreens.indices.contains(index) else { return }
        controller.createGroup(on: knownScreens[index])
    }
    @objc private func releaseGroup() { Task { await controller.release(restore: false); controller.refresh() } }
}

private final class GridPreview: NSView {
    var count = 0
    var layout = GridLayout(columns: 3, rows: 2)
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 4
        let width = (bounds.width - CGFloat(layout.columns - 1) * gap) / CGFloat(layout.columns)
        let height = (bounds.height - CGFloat(layout.rows - 1) * gap) / CGFloat(layout.rows)
        for index in 0..<layout.capacity {
            let rect = CGRect(x: CGFloat(index % layout.columns) * (width + gap), y: CGFloat(layout.rows - 1 - index / layout.columns) * (height + gap), width: width, height: height)
            let selected = index < count
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let string = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor]
            let size = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
