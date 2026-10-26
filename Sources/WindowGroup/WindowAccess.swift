import AppKit
import ApplicationServices

/// A reference to a live window. Geometry uses Accessibility's global,
/// top-left-origin screen coordinates, in points.
struct ManagedWindow: Identifiable, @unchecked Sendable {
    let id: UUID
    let pid: pid_t
    let appName: String
    let title: String
    let element: AXUIElement
    let originalFrame: CGRect
    /// Lower values are nearer the front of the current desktop.
    let stackingOrder: Int

    init(
        id: UUID = UUID(),
        pid: pid_t,
        appName: String,
        title: String,
        element: AXUIElement,
        originalFrame: CGRect,
        stackingOrder: Int = 0
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.element = element
        self.originalFrame = originalFrame
        self.stackingOrder = stackingOrder
    }
}

enum WindowAccessError: LocalizedError {
    case permissionRequired
    case invalidFrame
    case unavailableWindow
    case accessibility(operation: String, code: AXError)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Enable WindowGroup in System Settings → Privacy & Security → Accessibility."
        case .invalidFrame:
            return "The requested window size or position is invalid."
        case .unavailableWindow:
            return "This window is no longer available. Refresh the window list or remove it from the group."
        case let .accessibility(operation, code):
            switch code {
            case .invalidUIElement, .invalidUIElementObserver:
                return "The window closed or is no longer available."
            case .cannotComplete:
                return "The app did not respond while \(operation). Try again when it is responsive."
            case .attributeUnsupported, .notImplemented:
                return "This app does not support \(operation) through macOS Accessibility."
            case .apiDisabled:
                return "Accessibility access is disabled. Enable WindowGroup in System Settings."
            default:
                return "macOS could not complete \(operation) (Accessibility error \(code.rawValue))."
            }
        }
    }
}

/// Runs Accessibility operations off the UI actor. Individual IPC calls are
/// bounded; applyFrame also allows asynchronous AppKit frame changes to settle.
/// Callers serialize group writes because actor methods can reenter at awaits.
actor WindowAccess {
    private static let messagingTimeout: Float = 0.15
    private static let frameSettlingNanoseconds: UInt64 = 150_000_000
    private static let framePollNanoseconds: UInt64 = 25_000_000

    nonisolated static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    nonisolated static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Returns standard, movable, resizable windows on the current desktop.
    /// CG metadata is used only for visibility; there is no screenshot capture.
    func listWindows() -> [ManagedWindow] {
        guard Self.isTrusted else { return [] }
        let visibleFrames = onScreenFramesByProcess()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter {
                $0.processIdentifier != ownPID && !$0.isHidden && !$0.isTerminated
                    && $0.activationPolicy == .regular
                    && visibleFrames[$0.processIdentifier] != nil
            }

        var result: [ManagedWindow] = []
        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            configureTimeout(appElement)
            guard let windows: [AXUIElement] = attribute(kAXWindowsAttribute, of: appElement) else {
                continue
            }
            let focused: AXUIElement? = attribute(kAXFocusedWindowAttribute, of: appElement)
            let main: AXUIElement? = attribute(kAXMainWindowAttribute, of: appElement)
            func priority(_ window: AXUIElement) -> Int {
                if let focused, CFEqual(window, focused) { return 0 }
                if let main, CFEqual(window, main) { return 1 }
                return 2
            }
            // AX does not expose a public CG window identifier. Consume each
            // matching CG frame once, giving focused/main AX windows priority
            // when same-app windows occupy identical rectangles.
            let ordered = windows.enumerated().sorted {
                let lhs = priority($0.element), rhs = priority($1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
            var remainingVisible = visibleFrames[application.processIdentifier] ?? []
            for window in ordered {
                configureTimeout(window)
                guard
                    stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole,
                    stringAttribute(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole,
                    !boolAttribute(kAXMinimizedAttribute, of: window),
                    !boolAttribute("AXFullScreen", of: window),
                    isSettable(kAXPositionAttribute, on: window),
                    isSettable(kAXSizeAttribute, on: window),
                    let frame = frame(of: window),
                    let matchIndex = remainingVisible.firstIndex(where: {
                        approximatelyEqual($0.frame, frame, tolerance: 2)
                    })
                else {
                    continue
                }

                let visible = remainingVisible.remove(at: matchIndex)

                let title = stringAttribute(kAXTitleAttribute, of: window)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.append(ManagedWindow(
                    pid: application.processIdentifier,
                    appName: application.localizedName ?? "Application",
                    title: title.isEmpty ? "Untitled window" : title,
                    element: window,
                    originalFrame: frame,
                    stackingOrder: visible.order
                ))
            }
        }

        return result.sorted {
            let appOrder = $0.appName.localizedStandardCompare($1.appName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            if $0.originalFrame.minY != $1.originalFrame.minY {
                return $0.originalFrame.minY < $1.originalFrame.minY
            }
            return $0.originalFrame.minX < $1.originalFrame.minX
        }
    }

    func readFrame(_ window: ManagedWindow) -> CGRect? {
        guard Self.isTrusted else { return nil }
        return frame(of: window.element)
    }

    /// Returns the actual accepted frame, including application size clamps and
    /// terminal character-grid rounding. Callers must compare this with the
    /// requested frame before assuming that an equal-sized grid was achieved.
    /// A mismatch gets a bounded settling interval; a persistent valid mismatch
    /// is returned rather than treated as success or retried indefinitely.
    @discardableResult
    func applyFrame(_ requestedFrame: CGRect, to window: ManagedWindow) async throws -> CGRect {
        try Task.checkCancellation()
        guard Self.isTrusted else { throw WindowAccessError.permissionRequired }
        guard isValid(requestedFrame) else { throw WindowAccessError.invalidFrame }
        let before = try requiredFrame(of: window.element)
        if approximatelyEqual(before, requestedFrame, tolerance: 0.1) { return before }

        // AX has separate position and size setters. The first size change can
        // be constrained by the old display; retrying after moving allows the
        // destination display's available space to take effect.
        if before.size != requestedFrame.size {
            try setSize(requestedFrame.size, on: window.element)
        }
        if before.origin != requestedFrame.origin {
            try setPosition(requestedFrame.origin, on: window.element)
        }
        if before.size != requestedFrame.size {
            try setSize(requestedFrame.size, on: window.element)
        }

        var accepted = try requiredFrame(of: window.element)
        var correctedPosition = false
        func positionShifted(_ frame: CGRect) -> Bool {
            abs(frame.minX - requestedFrame.minX) > 0.1
                || abs(frame.minY - requestedFrame.minY) > 0.1
        }

        // A size setter can move an AppKit window to keep it on screen. This
        // includes the second size setter and the case where the original
        // position already matched, so always inspect the final origin.
        if positionShifted(accepted) {
            try setPosition(requestedFrame.origin, on: window.element)
            correctedPosition = true
            accepted = try requiredFrame(of: window.element)
        }
        if approximatelyEqual(accepted, requestedFrame, tolerance: 0.1) { return accepted }

        let deadline = DispatchTime.now().uptimeNanoseconds + Self.frameSettlingNanoseconds
        for _ in 0..<6 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            try await Task.sleep(nanoseconds: min(Self.framePollNanoseconds, deadline - now))
            try Task.checkCancellation()
            guard Self.isTrusted else { throw WindowAccessError.permissionRequired }
            // Throw on the first AX error or dead window; only valid, unequal
            // frames are candidates for settling. Do not retry failed IPC.
            accepted = try requiredFrame(of: window.element)
            if !correctedPosition && positionShifted(accepted) {
                // Some apps deliver the size-induced origin shift later.
                // Correct it once, without fighting a persistent app constraint.
                try setPosition(requestedFrame.origin, on: window.element)
                correctedPosition = true
                accepted = try requiredFrame(of: window.element)
            }
            if approximatelyEqual(accepted, requestedFrame, tolerance: 0.1) { return accepted }
        }

        return accepted
    }

    /// Raises a member without launching, closing, or terminating any app.
    func raise(_ window: ManagedWindow) {
        guard Self.isTrusted else { return }
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    func isAlive(_ window: ManagedWindow) -> Bool {
        guard Self.isTrusted else { return false }
        return stringAttribute(kAXRoleAttribute, of: window.element) == kAXWindowRole
            && !boolAttribute(kAXMinimizedAttribute, of: window.element)
            && !boolAttribute("AXFullScreen", of: window.element)
            && frame(of: window.element) != nil
    }

    private func configureTimeout(_ element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    private func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element)
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool {
        let value: NSNumber? = attribute(name, of: element)
        return value?.boolValue ?? false
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        try? requiredFrame(of: element)
    }

    /// The mutation path must distinguish an AX failure from an unsettled frame.
    /// Optional discovery/read paths intentionally discard these errors.
    private func requiredFrame(of element: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard positionError == .success else {
            throw WindowAccessError.accessibility(operation: "reading the window position", code: positionError)
        }
        guard let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            throw WindowAccessError.unavailableWindow
        }
        let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard sizeError == .success else {
            throw WindowAccessError.accessibility(operation: "reading the window size", code: sizeError)
        }
        guard let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw WindowAccessError.unavailableWindow
        }

        let axPosition = positionValue as! AXValue
        let axSize = sizeValue as! AXValue
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize else {
            throw WindowAccessError.unavailableWindow
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetValue(axSize, .cgSize, &size) else {
            throw WindowAccessError.unavailableWindow
        }
        let result = CGRect(origin: position, size: size)
        guard isValid(result) else { throw WindowAccessError.unavailableWindow }
        return result
    }

    private func setPosition(_ position: CGPoint, on element: AXUIElement) throws {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            throw WindowAccessError.invalidFrame
        }
        let error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard error == .success else {
            throw WindowAccessError.accessibility(operation: "moving the window", code: error)
        }
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw WindowAccessError.invalidFrame
        }
        let error = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard error == .success else {
            throw WindowAccessError.accessibility(operation: "resizing the window", code: error)
        }
    }

    private func onScreenFramesByProcess() -> [pid_t: [(frame: CGRect, order: Int)]] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var frames: [pid_t: [(frame: CGRect, order: Int)]] = [:]
        for (order, info) in windowInfo.enumerated() {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                isValid(frame)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 {
                continue
            }
            frames[pid_t(pid.int32Value), default: []].append((frame: frame, order: order))
        }
        return frames
    }

    private func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}
