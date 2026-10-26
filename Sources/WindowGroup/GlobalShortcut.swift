import AppKit
import Carbon

/// A system hot key, with no event tap or additional input-monitoring access.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?
    private nonisolated static let signature: OSType = 0x57475250 // WGRP

    /// Registers Control–Option–G. Returns false if macOS rejects registration
    /// (for example, because another app already owns the same shortcut).
    @discardableResult
    func register(handler: @escaping () -> Void) -> Bool {
        unregister()
        callback = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), Self.receiveHotKey, 1, &eventType,
            context, &eventHandler
        )
        guard installed == noErr else {
            unregister()
            return false
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        callback = nil
    }

    private nonisolated static let receiveHotKey: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard result == noErr, identifier.signature == signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor [weak owner] in owner?.callback?() }
        return noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
