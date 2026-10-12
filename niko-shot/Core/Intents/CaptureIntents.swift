// Exposes five native Shortcuts actions through the same validated resident execution bridge.
import AppIntents
import Foundation

extension AutomationRecordingFormat: AppEnum, CaseIterable {
    /// Formats presented by the recording action in Shortcuts.
    public static var allCases: [AutomationRecordingFormat] { [.mp4, .gif] }
    /// The localized type name shown by Shortcuts.
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "录屏格式" }
    /// Native labels for recording formats.
    public static var caseDisplayRepresentations: [AutomationRecordingFormat: DisplayRepresentation] {
        [.mp4: "MP4", .gif: "GIF"]
    }
}

/// Captures an interactively selected screen region and returns its output path.
public struct CaptureRegionIntent: AppIntent {
    /// The action name shown in Shortcuts.
    public static var title: LocalizedStringResource { "框选截图" }
    /// Runs in the resident application so permission and selection UI have one owner.
    public static var openAppWhenRun: Bool { true }
    /// Whole seconds before capture.
    @Parameter(title: "延时（秒）", default: 0, inclusiveRange: (0, 10)) public var delay: Int
    /// Optional file destination; tilde and relative paths are supported.
    @Parameter(title: "输出路径") public var outputPath: String?
    /// Whether the captured image should be recognized for searchable history.
    @Parameter(title: "自动 OCR", default: true) public var autoOCR: Bool
    /// Creates the default region capture action.
    public init() {}
    /// Executes the resident capture and returns its saved path or status.
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AutomationBridge.shared.execute(AutomationCommand(action: .capture,
            delay: delay, outputPath: outputPath, autoOCR: autoOCR))
        return .result(value: result.outputPath ?? result.message)
    }
}

/// Captures a selected window, optionally identified by its Core Graphics identifier.
public struct CaptureWindowIntent: AppIntent {
    /// The action name shown in Shortcuts.
    public static var title: LocalizedStringResource { "窗口截图" }
    /// Opens the resident app for selection and permission UI.
    public static var openAppWhenRun: Bool { true }
    /// Whole seconds before capture.
    @Parameter(title: "延时（秒）", default: 0, inclusiveRange: (0, 10)) public var delay: Int
    /// Optional file destination.
    @Parameter(title: "输出路径") public var outputPath: String?
    /// Whether to recognize the captured image.
    @Parameter(title: "自动 OCR", default: true) public var autoOCR: Bool
    /// An optional positive Core Graphics window identifier.
    @Parameter(title: "窗口 ID") public var windowID: Int?
    /// Creates the default interactive window action.
    public init() {}
    /// Executes one window capture and returns its saved path or status.
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var identifier: UInt32?
        if let windowID {
            guard let value = UInt32(exactly: windowID), value > 0 else {
                throw AutomationError.invalidArguments("窗口 ID 必须为有效的正整数。")
            }
            identifier = value
        }
        let result = try await AutomationBridge.shared.execute(AutomationCommand(action: .capture,
            captureType: .window, delay: delay, outputPath: outputPath, autoOCR: autoOCR, windowID: identifier))
        return .result(value: result.outputPath ?? result.message)
    }
}

/// Starts recording through the resident capture controls and returns the final file path.
public struct StartRecordingIntent: AppIntent {
    /// The action name shown in Shortcuts.
    public static var title: LocalizedStringResource { "开始录屏" }
    /// Opens the resident app for recording controls.
    public static var openAppWhenRun: Bool { true }
    /// Whole seconds before recording.
    @Parameter(title: "延时（秒）", default: 0, inclusiveRange: (0, 10)) public var delay: Int
    /// Optional destination for the final recording.
    @Parameter(title: "输出路径") public var outputPath: String?
    /// Carries the common automation OCR preference.
    @Parameter(title: "自动 OCR", default: true) public var autoOCR: Bool
    /// The exported recording format.
    @Parameter(title: "格式", default: .mp4) public var format: AutomationRecordingFormat
    /// Creates the default MP4 recording action.
    public init() {}
    /// Waits for the resident recording operation to complete.
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AutomationBridge.shared.execute(AutomationCommand(action: .record,
            delay: delay, outputPath: outputPath, autoOCR: autoOCR, recordingFormat: format))
        return .result(value: result.outputPath ?? result.message)
    }
}

/// Opens scrolling capture and returns the edited long image's output path.
public struct ScrollCaptureIntent: AppIntent {
    /// The action name shown in Shortcuts.
    public static var title: LocalizedStringResource { "滚动长截图" }
    /// Opens the resident app for viewport selection and scrolling controls.
    public static var openAppWhenRun: Bool { true }
    /// Whole seconds before capture.
    @Parameter(title: "延时（秒）", default: 0, inclusiveRange: (0, 10)) public var delay: Int
    /// Optional destination for the finished long image.
    @Parameter(title: "输出路径") public var outputPath: String?
    /// Whether to recognize the finished image.
    @Parameter(title: "自动 OCR", default: true) public var autoOCR: Bool
    /// Creates the default scrolling action.
    public init() {}
    /// Waits for scrolling, editing and output to finish in the resident application.
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AutomationBridge.shared.execute(AutomationCommand(action: .scroll,
            delay: delay, outputPath: outputPath, autoOCR: autoOCR))
        return .result(value: result.outputPath ?? result.message)
    }
}

/// Returns the latest recognized text without installing any capture listener.
public struct LastOCRTextIntent: AppIntent {
    /// The action name shown in Shortcuts.
    public static var title: LocalizedStringResource { "获取最近 OCR 文本" }
    /// Ensures the resident OCR history owner executes the request.
    public static var openAppWhenRun: Bool { true }
    /// Creates the text retrieval action.
    public init() {}
    /// Returns recognized text directly as a Shortcuts string result.
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AutomationBridge.shared.execute(AutomationCommand(action: .lastOCR))
        return .result(value: result.text ?? "")
    }
}
