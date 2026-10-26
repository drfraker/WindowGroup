import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: GroupController!
    private var picker: WindowPicker!
    private var statusItem: NSStatusItem!
    private let desktopSelection = SelectionOverlay()
    private let shortcut = GlobalShortcut()
    private var selectionStarting = false
    private var confirmingSelection = false
    private var selectionGeneration = 0
    private var terminating = false
    private var desktopCandidates: [ManagedWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        controller = GroupController()
        picker = WindowPicker(controller: controller)
        picker.onStartDesktopSelection = { [weak self] in self?.startDesktopSelection() }
        desktopSelection.onCancel = { [weak self] in
            self?.selectionGeneration += 1
            self?.selectionStarting = false
            self?.controller.setDesktopSelectionActive(false)
        }
        desktopSelection.onConfirm = { [weak self] chosen, screen in
            guard let self else { return }
            let candidates = self.desktopCandidates
            let token = self.selectionGeneration
            self.confirmingSelection = true
            Task { @MainActor in
                await self.controller.release(restore: false)
                guard token == self.selectionGeneration && !self.terminating else {
                    self.confirmingSelection = false
                    return
                }
                self.controller.setDesktopSelectionActive(false)
                self.controller.adoptDesktopSelection(chosen, from: candidates)
                self.picker.preferDisplay(screen)
                self.confirmingSelection = false
                self.picker.present(refresh: false)
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "WindowGroup") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "WG"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Select on Desktop   ⌃⌥G", action: #selector(selectOnDesktop), keyEquivalent: "")
        menu.addItem(withTitle: "Select Windows…", action: #selector(selectWindows), keyEquivalent: "")
        menu.addItem(withTitle: "Show Group", action: #selector(showGroup), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Restore Original Positions", action: #selector(restore), keyEquivalent: "")
        menu.addItem(withTitle: "Release Group", action: #selector(releaseGroup), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit WindowGroup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        if let index = CommandLine.arguments.firstIndex(of: "--integration-check"), CommandLine.arguments.indices.contains(index + 1), let pid = Int32(CommandLine.arguments[index + 1]) {
            Task {
                let report = await runIntegrationCheck(fixturePID: pid, access: controller.access)
                print(report)
                if let reportIndex = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(reportIndex + 1) {
                    try? report.write(toFile: CommandLine.arguments[reportIndex + 1], atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        } else {
            picker.setShortcutAvailable(shortcut.register { [weak self] in self?.startDesktopSelection() })
            picker.present()
        }
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WindowGroup", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit WindowGroup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let file = NSMenuItem()
        file.title = "File"
        file.submenu = NSMenu(title: "File")
        let select = file.submenu!.addItem(withTitle: "Select Windows…", action: #selector(selectWindows), keyEquivalent: "n")
        select.target = self
        let desktop = file.submenu!.addItem(withTitle: "Select on Desktop", action: #selector(selectOnDesktop), keyEquivalent: "g")
        desktop.keyEquivalentModifierMask = [.control, .option]
        desktop.target = self
        main.addItem(file)
        let edit = NSMenuItem()
        edit.title = "Edit"
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    @objc private func selectWindows() {
        guard !confirmingSelection, !terminating else { return }
        desktopSelection.cancel()
        picker.present()
    }
    @objc private func selectOnDesktop() { startDesktopSelection() }
    private func startDesktopSelection() {
        if desktopSelection.isActive { desktopSelection.cancel(); return }
        guard !selectionStarting, !confirmingSelection, !terminating, !controller.busy else { NSSound.beep(); return }
        guard WindowAccess.isTrusted else {
            picker.present()
            return
        }
        selectionStarting = true
        selectionGeneration += 1
        let token = selectionGeneration
        picker.window?.orderOut(nil)
        controller.setDesktopSelectionActive(true)
        desktopSelection.beginLoading()
        Task {
            let candidates = await controller.access.listWindows()
            guard token == selectionGeneration && desktopSelection.isActive && !terminating else { return }
            selectionStarting = false
            guard WindowAccess.isTrusted else {
                desktopSelection.cancel()
                picker.present()
                return
            }
            desktopCandidates = candidates
            desktopSelection.completeLoading(windows: candidates)
        }
    }
    @objc private func showGroup() { controller.showGroup() }
    @objc private func restore() { Task { await controller.release(restore: true) } }
    @objc private func releaseGroup() { Task { await controller.release(restore: false) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { selectWindows(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        selectionGeneration += 1
        desktopSelection.cancel()
        shortcut.unregister()
        guard controller?.hasGroup == true else { return .terminateNow }
        Task {
            await controller.release(restore: false)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
