import Carbon.HIToolbox

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) static var handlerInstalled = false
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private(set) var isRegistered = false

    init(keyCode: Int = kVK_ANSI_X, modifiers: Int = cmdKey | shiftKey, action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()
        Self.actions[id] = { MainActor.assumeIsolated(action) }
        isRegistered = register(keyCode: keyCode, modifiers: modifiers)
    }

    isolated deinit {
        unregister()
        Self.actions[id] = nil
    }

    @discardableResult
    func update(keyCode: Int, modifiers: Int) -> Bool {
        unregister()
        isRegistered = register(keyCode: keyCode, modifiers: modifiers)
        return isRegistered
    }

    private func register(keyCode: Int, modifiers: Int) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5841_4D4E), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr { reference = nil }
        return status == noErr
    }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
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
