// Owns Carbon global hotkeys, persistence and actionable conflict reporting without input monitoring.
import AppKit
import Carbon
import Observation

/// Keyboard-accessible application commands.
public enum CaptureAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case region, window, fullscreen, repeatRegion, record, ocr, scroll, pins, togglePins

    public var id: String { rawValue }

    /// Localized name used in menus and settings.
    public var title: String {
        switch self {
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullscreen: "全屏截图"
        case .repeatRegion: "重复上次区域"
        case .record: "录屏"
        case .ocr: "识别文字"
        case .scroll: "滚动长截图"
        case .pins: "贴图库"
        case .togglePins: "显示 / 隐藏全部贴图"
        }
    }

    /// SF Symbol used for this command.
    public var symbol: String {
        switch self {
        case .region: "crop"
        case .window: "macwindow"
        case .fullscreen: "rectangle.inset.filled"
        case .repeatRegion: "arrow.counterclockwise"
        case .record: "record.circle"
        case .ocr: "text.viewfinder"
        case .scroll: "scroll"
        case .pins: "pin"
        case .togglePins: "eye"
        }
    }

    /// The specification's default global shortcut.
    public var defaultShortcut: HotkeyShortcut {
        let code: Int
        switch self {
        case .region: code = kVK_ANSI_A
        case .window: code = kVK_ANSI_W
        case .fullscreen: code = kVK_ANSI_F
        case .repeatRegion: code = kVK_ANSI_R
        case .record: code = kVK_ANSI_V
        case .ocr: code = kVK_ANSI_O
        case .scroll: code = kVK_ANSI_L
        case .pins: code = kVK_ANSI_P
        case .togglePins: code = kVK_ANSI_T
        }
        let modifiers = self == .togglePins ? UInt32(optionKey | cmdKey) : UInt32(shiftKey | cmdKey)
        return HotkeyShortcut(keyCode: UInt32(code), modifiers: modifiers)
    }
}

/// A physical macOS key and Carbon modifier mask, independent of permissions.
public struct HotkeyShortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    /// Creates a shortcut, retaining only supported modifier bits.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & UInt32(cmdKey | shiftKey | optionKey | controlKey)
    }

    /// Requires Command, Option or Control to avoid consuming ordinary typing.
    public var isValid: Bool {
        keyCode <= 127 && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// A compact native key-equivalent presentation.
    public var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyNames[keyCode, default: "键 \(keyCode)"]
    }

    /// Converts event flags to the bits understood by RegisterEventHotKey.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "空格", 50: "`", 51: "⌫", 53: "⎋", 65: "数字 .", 67: "数字 *",
        69: "数字 +", 71: "清除", 75: "数字 /", 76: "⌤", 78: "数字 −", 81: "数字 =",
        82: "数字 0", 83: "数字 1", 84: "数字 2", 85: "数字 3", 86: "数字 4", 87: "数字 5",
        88: "数字 6", 89: "数字 7", 91: "数字 8", 92: "数字 9", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "帮助", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

/// A failed assignment with the attempted shortcut and an inline explanation.
public struct HotkeyRegistrationIssue: Equatable, Sendable {
    public let shortcut: HotkeyShortcut
    public let status: Int32?
    public let message: String
}

/// Registers and releases application hotkeys using Carbon's event-driven API.
@MainActor @Observable
public final class HotkeyCenter {
    /// Requested shortcuts, restored from preferences on launch.
    public private(set) var shortcuts: [CaptureAction: HotkeyShortcut]
    /// Registration or assignment failures, suitable for inline settings feedback.
    public private(set) var registrationErrors: [CaptureAction: HotkeyRegistrationIssue] = [:]
    /// Commands whose current shortcut is successfully registered.
    public private(set) var registeredActions: Set<CaptureAction> = []
    /// Whether the Carbon application event handler is installed.
    public private(set) var isRunning = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var actions: [CaptureAction: () -> Void]
    // Carbon refs are mutated only on MainActor. Nonisolated storage permits synchronous
    // C-resource destruction on macOS 14/15, avoiding Swift 6.2 isolated-deinit runtime bugs.
    @ObservationIgnored nonisolated(unsafe) private var references: [CaptureAction: EventHotKeyRef] = [:]
    @ObservationIgnored nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private static let preferenceKey = "globalHotkeys"
    private static let signature: UInt32 = 0x4E534854

    /// Creates a center; tests can defer system registration to avoid reserving keys.
    public init(actions: [CaptureAction: () -> Void], defaults: UserDefaults = .standard, registersImmediately: Bool = true) {
        self.actions = actions
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode([String: HotkeyShortcut].self, from: $0) } ?? [:]
        shortcuts = Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { action in
            let restored = saved[action.rawValue]
            return (action, restored?.isValid == true ? restored ?? action.defaultShortcut : action.defaultShortcut)
        })
        if registersImmediately { start() }
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Installs one application event handler and registers the persisted shortcuts.
    public func start() {
        guard !isRunning else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.eventCallback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            for action in CaptureAction.allCases {
                registrationErrors[action] = HotkeyRegistrationIssue(shortcut: shortcut(for: action), status: status, message: "无法安装热键处理器（\(status)）。请重启应用后重试。")
            }
            return
        }
        isRunning = true
        for action in CaptureAction.allCases { register(action) }
    }

    /// Removes every registration and the event handler; calling it repeatedly is safe.
    public func stop() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        registeredActions.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isRunning = false
    }

    /// Returns the persisted shortcut or its specified default.
    public func shortcut(for action: CaptureAction) -> HotkeyShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Updates a command callback without reinstalling its shortcut.
    public func setAction(_ action: CaptureAction, perform: @escaping () -> Void) {
        actions[action] = perform
    }

    /// Saves and registers a shortcut; duplicate assignments retain the existing key.
    @discardableResult public func setShortcut(_ shortcut: HotkeyShortcut, for action: CaptureAction) -> Bool {
        guard shortcut.isValid else {
            registrationErrors[action] = HotkeyRegistrationIssue(shortcut: shortcut, status: nil, message: "请使用包含 ⌘、⌥ 或 ⌃ 的组合键。")
            return false
        }
        if let conflict = CaptureAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            registrationErrors[action] = HotkeyRegistrationIssue(shortcut: shortcut, status: nil, message: "\(shortcut.displayString) 已分配给「\(conflict.title)」。原有快捷键仍可使用。")
            return false
        }
        if let reference = references.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
        registeredActions.remove(action)
        registrationErrors.removeValue(forKey: action)
        shortcuts[action] = shortcut
        persist()
        if isRunning { register(action) }
        return registrationErrors[action] == nil
    }

    /// Restores all specified defaults and retries their registrations.
    public func resetDefaults() {
        let wasRunning = isRunning
        stop()
        shortcuts = Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { ($0, $0.defaultShortcut) })
        registrationErrors.removeAll()
        persist()
        if wasRunning { start() }
    }

    /// Suggests alternate combinations that are not assigned inside this application.
    public func suggestions(for action: CaptureAction) -> [HotkeyShortcut] {
        let current = registrationErrors[action]?.shortcut ?? shortcut(for: action)
        let combinations = [UInt32(controlKey | shiftKey | cmdKey), UInt32(optionKey | shiftKey | cmdKey), UInt32(controlKey | optionKey | cmdKey)]
        return combinations.map { HotkeyShortcut(keyCode: current.keyCode, modifiers: $0) }
            .filter { candidate in candidate != current && !CaptureAction.allCases.contains { self.shortcut(for: $0) == candidate } }
    }

    private func persist() {
        let values = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.preferenceKey) }
    }

    private func register(_ action: CaptureAction) {
        guard let index = CaptureAction.allCases.firstIndex(of: action) else { return }
        let shortcut = shortcut(for: action)
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references[action] = reference
            registeredActions.insert(action)
            registrationErrors.removeValue(forKey: action)
        } else {
            registrationErrors[action] = HotkeyRegistrationIssue(shortcut: shortcut, status: status, message: "\(shortcut.displayString) 无法注册，可能已被系统或其他应用占用（\(status)）。请选择替代组合。")
        }
    }

    private func perform(identifier: UInt32) {
        guard identifier > 0, Int(identifier) <= CaptureAction.allCases.count else { return }
        let action = CaptureAction.allCases[Int(identifier) - 1]
        guard registeredActions.contains(action) else { return }
        actions[action]?()
    }

    private nonisolated static let eventCallback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == 0x4E534854 else { return OSStatus(eventNotHandledErr) }
        let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
        let value = identifier.id
        Task { @MainActor [weak center] in center?.perform(identifier: value) }
        return noErr
    }
}
