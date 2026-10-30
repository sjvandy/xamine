import Carbon.HIToolbox

/// A system-wide keyboard shortcut registered through Carbon (needs no extra permission).
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) static var handlerInstalled = false
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Defaults to ⌘⇧X.
    init(keyCode: Int = kVK_ANSI_X, modifiers: Int = cmdKey | shiftKey, action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()
        Self.actions[id] = { MainActor.assumeIsolated(action) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5841_4D4E), id: id) // 'XAMN'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
