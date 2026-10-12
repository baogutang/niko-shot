// Defines the shared, text-free contract used by Shortcuts, URL schemes and the CLI.
import Foundation

/// An operation executed by the resident application.
public enum AutomationAction: String, Codable, Sendable {
    /// Select or capture an image.
    case capture
    /// Capture an image, recognize it and copy its text.
    case ocr
    /// Translate the current clipboard text.
    case translate
    /// Start an interactive recording.
    case record
    /// Start an interactive scrolling capture.
    case scroll
    /// Return the most recent recognized text.
    case lastOCR
}

/// The source selected for image or recording capture.
public enum AutomationCaptureType: String, Codable, Sendable {
    /// Ask the user to select a region.
    case region
    /// Capture a selected or explicitly identified window.
    case window
    /// Capture the full screen.
    case fullscreen
}

/// The final format of an automated recording.
public enum AutomationRecordingFormat: String, Codable, Sendable {
    /// Export an HEVC/AAC MP4 recording.
    case mp4
    /// Export an animated GIF.
    case gif
}

/// Validation and transport errors shared by all automation entry points.
public enum AutomationError: Error, LocalizedError, Equatable, Sendable {
    /// The command contains an invalid or unsupported argument.
    case invalidArguments(String)
    /// The resident application has not installed its execution handler.
    case unavailable
    /// The resident did not answer before the request deadline.
    case timeout
    /// A response failed validation.
    case invalidResponse(String)
    /// The resident operation failed.
    case executionFailed(String)

    /// A readable description suitable for Shortcuts and standard error.
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return "参数错误：\(message)"
        case .unavailable: return "niko-shot 尚未准备好执行自动化命令。"
        case .timeout: return "等待 niko-shot 响应超时。"
        case .invalidResponse(let message): return "自动化响应无效：\(message)"
        case .executionFailed(let message): return message
        }
    }
}

/// Metadata only: clipboard contents, recognized text and credentials never belong in a command.
public struct AutomationCommand: Codable, Sendable, Equatable {
    /// The requested operation.
    public var action: AutomationAction
    /// The image or recording source; defaults to an interactive region.
    public var captureType: AutomationCaptureType
    /// Whole seconds to wait before capture, from zero through ten.
    public var delay: Int
    /// An optional file destination, normalized by ``validated()``.
    public var outputPath: String?
    /// Whether captured images should also be recognized for history.
    public var autoOCR: Bool
    /// The target language code for translation; defaults to `zh`.
    public var targetLanguage: String?
    /// The recording export format.
    public var recordingFormat: AutomationRecordingFormat
    /// A positive Core Graphics window identifier when the source is a window.
    public var windowID: UInt32?

    /// Creates a command without accessing the clipboard, permissions or capture APIs.
    public init(action: AutomationAction, captureType: AutomationCaptureType = .region,
                delay: Int = 0, outputPath: String? = nil, autoOCR: Bool = true,
                targetLanguage: String? = nil, recordingFormat: AutomationRecordingFormat = .mp4,
                windowID: UInt32? = nil) {
        self.action = action; self.captureType = captureType; self.delay = delay
        self.outputPath = outputPath; self.autoOCR = autoOCR
        self.targetLanguage = action == .translate ? targetLanguage ?? "zh" : targetLanguage
        self.recordingFormat = recordingFormat; self.windowID = windowID
    }

    /// Validates scalar values and expands file paths without creating files.
    public func validated() throws -> AutomationCommand {
        guard (0...10).contains(delay) else { throw AutomationError.invalidArguments("delay 必须为 0–10 的整数。") }
        if let windowID {
            guard windowID > 0, captureType == .window, action == .capture || action == .ocr else {
                throw AutomationError.invalidArguments("windowID 必须为正整数，并配合 capture/ocr 的窗口捕获模式。")
            }
        }
        guard recordingFormat == .mp4 || action == .record else {
            throw AutomationError.invalidArguments("format 仅适用于 record。")
        }
        var result = self
        if let outputPath {
            guard !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !outputPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AutomationError.invalidArguments("output 不得为空或包含控制字符。")
            }
            let expanded = (outputPath as NSString).expandingTildeInPath
            guard !expanded.hasPrefix("~") else { throw AutomationError.invalidArguments("无法展开 output 中的用户目录。") }
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let path = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard path != "/", !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue) else {
                throw AutomationError.invalidArguments("output 必须指向文件，不能指向目录。")
            }
            result.outputPath = path
        }
        if action == .translate {
            let value = (targetLanguage ?? "zh").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let aliases = ["zh": "zh", "zh-cn": "zh", "zh-hans": "zh", "zh-tw": "zh-Hant", "zh-hant": "zh-Hant",
                           "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "de": "de", "es": "es",
                           "pt": "pt", "ru": "ru", "it": "it", "th": "th", "ar": "ar", "vi": "vi", "id": "id"]
            guard let normalized = aliases[value] else { throw AutomationError.invalidArguments("不支持的目标语言：\(value)。") }
            result.targetLanguage = normalized
        } else if targetLanguage != nil {
            throw AutomationError.invalidArguments("to 仅适用于 translate。")
        }
        return result
    }

    /// Parses CLI arguments excluding the executable name, rejecting duplicates and unknown flags.
    public static func parse(arguments: [String]) throws -> AutomationCommand {
        guard let name = arguments.first, let action = action(named: name) else {
            throw AutomationError.invalidArguments("命令应为 capture、ocr、translate、record、scroll 或 last-ocr。")
        }
        var command = AutomationCommand(action: action), seen = Set<String>(), index = 1
        func claim(_ key: String) throws {
            guard seen.insert(key).inserted else { throw AutomationError.invalidArguments("参数 \(key) 重复。") }
        }
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw AutomationError.invalidArguments("\(flag) 缺少值。")
            }
            index += 1; return arguments[index]
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--region", "--window", "--fullscreen":
                try require(action, in: [.capture, .ocr, .record], argument: flag); try claim("type")
                guard let type = AutomationCaptureType(rawValue: String(flag.dropFirst(2))) else { throw AutomationError.invalidArguments("无效捕获模式。") }
                command.captureType = type
            case "--delay":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: flag); try claim("delay")
                let raw = try value(after: flag)
                guard let delay = Int(raw) else { throw AutomationError.invalidArguments("delay 必须为整数。") }
                command.delay = delay
            case "--output":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: flag); try claim("output")
                command.outputPath = try value(after: flag)
            case "--auto-ocr", "--no-auto-ocr":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: flag); try claim("autoOCR")
                command.autoOCR = flag == "--auto-ocr"
            case "--window-id":
                try require(action, in: [.capture, .ocr, .record], argument: flag); try claim("windowID")
                let raw = try value(after: flag)
                guard let id = UInt32(raw) else { throw AutomationError.invalidArguments("windowID 必须为正整数。") }
                command.windowID = id
            case "--to":
                try require(action, in: [.translate], argument: flag); try claim("to")
                command.targetLanguage = try value(after: flag)
            case "--format":
                try require(action, in: [.record], argument: flag); try claim("format")
                let raw = try value(after: flag)
                guard let format = AutomationRecordingFormat(rawValue: raw) else { throw AutomationError.invalidArguments("format 应为 mp4 或 gif。") }
                command.recordingFormat = format
            case "--clipboard":
                try require(action, in: [.ocr], argument: flag); try claim("clipboard")
            default: throw AutomationError.invalidArguments("未知参数：\(flag)。")
            }
            index += 1
        }
        return try command.validated()
    }

    /// Parses the registered URL scheme without accepting arbitrary hosts, paths or duplicate query items.
    public static func parse(url: URL) throws -> AutomationCommand {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "niko-shot", let host = parts.host,
              let action = action(named: host), parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil else {
            throw AutomationError.invalidArguments("URL 应为 niko-shot://capture、ocr、translate、record、scroll 或 last-ocr。")
        }
        var command = AutomationCommand(action: action), seen = Set<String>()
        for item in parts.queryItems ?? [] {
            let key = item.name == "auto-ocr" ? "autoOCR" : item.name == "window-id" ? "windowID" : item.name
            guard seen.insert(key).inserted else { throw AutomationError.invalidArguments("URL 参数 \(key) 重复。") }
            guard let value = item.value else { throw AutomationError.invalidArguments("URL 参数 \(key) 缺少值。") }
            switch key {
            case "type":
                try require(action, in: [.capture, .ocr, .record], argument: key)
                guard let type = AutomationCaptureType(rawValue: value) else { throw AutomationError.invalidArguments("type 应为 region、window 或 fullscreen。") }
                command.captureType = type
            case "delay":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: key)
                guard let delay = Int(value) else { throw AutomationError.invalidArguments("delay 必须为整数。") }
                command.delay = delay
            case "output":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: key); command.outputPath = value
            case "autoOCR":
                try require(action, in: [.capture, .ocr, .record, .scroll], argument: key)
                guard let enabled = ["true": true, "false": false, "1": true, "0": false][value] else { throw AutomationError.invalidArguments("autoOCR 应为 true、false、1 或 0。") }
                command.autoOCR = enabled
            case "format":
                try require(action, in: [.record], argument: key)
                guard let format = AutomationRecordingFormat(rawValue: value) else { throw AutomationError.invalidArguments("format 应为 mp4 或 gif。") }
                command.recordingFormat = format
            case "windowID":
                try require(action, in: [.capture, .ocr, .record], argument: key)
                guard let id = UInt32(value) else { throw AutomationError.invalidArguments("windowID 必须为正整数。") }
                command.windowID = id
            case "to":
                try require(action, in: [.translate], argument: key); command.targetLanguage = value
            default: throw AutomationError.invalidArguments("未知 URL 参数：\(item.name)。")
            }
        }
        return try command.validated()
    }

    private static func action(named name: String) -> AutomationAction? {
        name == "last-ocr" ? .lastOCR : AutomationAction(rawValue: name)
    }
    private static func require(_ action: AutomationAction, in actions: [AutomationAction], argument: String) throws {
        guard actions.contains(action) else { throw AutomationError.invalidArguments("\(argument) 不适用于 \(action.rawValue)。") }
    }
}

/// An execution result; any text is returned privately rather than posted as a distributed notification.
public struct AutomationResponse: Codable, Sendable, Equatable {
    /// The saved capture or recording path, if present.
    public var outputPath: String?
    /// Recognized or translated text, if present.
    public var text: String?
    /// A human-readable status message.
    public var message: String
    /// Creates the result returned by the resident execution handler.
    public init(outputPath: String? = nil, text: String? = nil, message: String = "") {
        self.outputPath = outputPath; self.text = text; self.message = message
    }
}
