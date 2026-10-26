import AppKit

/// Harmless, disposable windows for exercising WindowGroup's Accessibility
/// backend. This executable does not ask for Accessibility access itself.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(420, max(200, available.width - 200))
        let height = min(250, max(150, available.height - 200))
        for index in 1...6 {
            let offset = CGFloat(index - 1) * 22
            let contentRect = CGRect(
                x: available.minX + 30 + offset,
                y: available.maxY - height - 65 - offset,
                width: width,
                height: height
            )
            let window = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WG Fixture \(index)"
            window.contentMinSize = NSSize(width: 160, height: 100)
            window.isReleasedWhenClosed = false
            window.delegate = self

            let heading = NSTextField(labelWithString: "Test window \(index)")
            heading.font = .systemFont(ofSize: 23, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString:
                "Disposable window for the WindowGroup integration check. No project or document is open here.")
            detail.textColor = .secondaryLabelColor
            let input = NSTextField(string: "Type here to check focus")
            input.placeholderString = "A normal editable field"
            let stack = NSStackView(views: [heading, detail, input])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                    stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
                    stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                    input.widthAnchor.constraint(equalTo: stack.widthAnchor)
                ])
            }
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let appMenu = NSMenu()
    let appItem = NSMenuItem()
    let commands = NSMenu()
    commands.addItem(withTitle: "Quit WindowGroup Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = commands
    appMenu.addItem(appItem)
    application.mainMenu = appMenu
    let delegate = FixtureDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
