import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌘⌥⌃⇧.
    var modifiers: UInt
    var keyLabel: String

    static let defaultSnip = Shortcut(
        keyCode: UInt32(kVK_ANSI_S), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "S")
    static let defaultQuickSearch = Shortcut(
        keyCode: UInt32(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "K")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + keyLabel
    }

    var carbonModifiers: UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Builds a shortcut from a key press, or nil when it has no ⌘, ⌥ or ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let label = Self.specialKeys[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, keyLabel: label)
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
}

/// System-wide shortcuts via Carbon hot keys. Needs no accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var definitions: [UInt32: (shortcut: Shortcut, action: () -> Void)] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private(set) var suspended = false
    /// IDs whose shortcut the system refused, usually because another app already owns it.
    private(set) var failed: Set<UInt32> = []
    var onStatusChange: (() -> Void)?

    func set(id: UInt32, shortcut: Shortcut, action: @escaping () -> Void) {
        definitions[id] = (shortcut, action)
        if !suspended { register(id) }
    }

    /// Releases every shortcut while the user records a new one.
    func suspend() {
        suspended = true
        for id in Array(refs.keys) { unregister(id) }
    }

    func resume() {
        suspended = false
        for id in definitions.keys { register(id) }
    }

    func shortcut(for id: UInt32) -> Shortcut? { definitions[id]?.shortcut }

    fileprivate func fire(_ id: UInt32) { definitions[id]?.action() }

    private func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func register(_ id: UInt32) {
        installHandlerIfNeeded()
        unregister(id)
        guard let definition = definitions[id] else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x4B_45_50_54 /* KEPT */, id: id)
        let status = RegisterEventHotKey(
            definition.shortcut.keyCode, definition.shortcut.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            failed.remove(id)
        } else {
            failed.insert(id)
        }
        onStatusChange?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
