// Registers short-lived global keys (Return / Escape) while a nonactivating capture HUD is in charge.
import AppKit
import Carbon

/// Carbon hotkeys need no Input Monitoring consent; they exist only between `register` and `unregister`.
@MainActor
final class TransientHotkeys {
    private static let signature: UInt32 = 0x4E53_5448 // "NSTH"
    nonisolated(unsafe) private var references: [EventHotKeyRef] = []
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    var count: Int { references.count }

    deinit {
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers unmodified keys; a key already taken by another app is skipped silently.
    func register(_ bindings: [(keyCode: Int, action: () -> Void)]) {
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &type,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return }
        for (index, binding) in bindings.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            if RegisterEventHotKey(UInt32(binding.keyCode), 0, identifier, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                references.append(reference)
                actions[identifier.id] = binding.action
            }
        }
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll(); actions.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func perform(_ id: UInt32) { actions[id]?() }

    private nonisolated static let callback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == 0x4E53_5448 else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<TransientHotkeys>.fromOpaque(context).takeUnretainedValue()
        let value = identifier.id
        Task { @MainActor [weak owner] in owner?.perform(value) }
        return noErr
    }
}
