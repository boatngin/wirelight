import Carbon
import Foundation

/// A keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌃⌥⌘W.
    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W),
                                       modifiers: UInt32(cmdKey | optionKey | controlKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Printable name of a virtual key code for the current keyboard layout.
    static func keyName(_ keyCode: UInt32) -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeUnretainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)?.takeUnretainedValue() as CFData?,
              let ptr = CFDataGetBytePtr(data) else { return "?" }
        let layout = ptr.assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var len: UniCharCount = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), 0, &dead, UniCharCount(chars.count), &len, &chars)
        guard status == noErr, len > 0 else { return "?" }
        return String(utf16CodeUnits: chars[0..<Int(len)], count: Int(len)).uppercased()
    }
}

/// Registers one global hot key through Carbon's `RegisterEventHotKey`,
/// which works without the Accessibility permission, and forwards presses to `onTrigger`.
final class GlobalHotKey {
    var onTrigger: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x77676C74  // 'wglt'
    private static let hotKeyID: UInt32 = 1

    func update(_ combo: HotKeyCombo?) {
        unregister()
        guard let combo else { return }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) != noErr {
            ref = nil
        }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        self.ref = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        if InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &spec,
                               Unmanaged.passUnretained(self).toOpaque(), &handler) != noErr {
            handler = nil
        }
    }

    private static let callback: EventHandlerProcPtr = { _, event, userData in
        guard let event, let userData else { return noErr }
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, ByteCount(MemoryLayout<EventHotKeyID>.size), nil, &id) == noErr else { return noErr }
        guard id.signature == Self.signature, id.id == Self.hotKeyID else { return noErr }
        Unmanaged<GlobalHotKey>.fromRaw(userData).takeUnretainedValue().onTrigger?()
        return noErr
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}
