// Persists non-secret preferences; credentials are intentionally owned by the Keychain layer.
import Foundation
import Observation

/// A named point-size preset available when selecting a screenshot region.
public struct CaptureSizePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var width: Double
    public var height: Double

    /// Creates a region preset using AppKit points rather than backing pixels.
    public init(id: UUID = UUID(), name: String, width: Double, height: Double) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

/// Main-actor preferences shared by native settings and application services.
@MainActor @Observable
public final class AppSettings {
    /// The application's standard preference store.
    public static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    /// Delay in seconds before capture; zero captures immediately.
    public var captureDelay: Int { didSet { defaults.set(captureDelay, forKey: "captureDelay") } }
    /// Displays selection sizes in backing pixels instead of points.
    public var showsPixels: Bool { didSet { defaults.set(showsPixels, forKey: "showsPixels") } }
    /// User-defined region sizes in points.
    public var presetSizes: [CaptureSizePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presetSizes) { defaults.set(data, forKey: "presetSizes") }
        }
    }
    /// ImageIO format identifier: png, jpeg, heif or tiff.
    public var exportFormatRaw: String { didSet { defaults.set(exportFormatRaw, forKey: "exportFormat") } }
    /// JPEG encoder quality between zero and one.
    public var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: "jpegQuality") } }
    /// Filename without the format extension; supports date, time and sequence tokens.
    public var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "filenameTemplate") } }
    /// Recognizes saved captures for history search.
    public var autoOCR: Bool { didSet { defaults.set(autoOCR, forKey: "autoOCR") } }
    /// Recognition language tags accepted by Vision.
    public var ocrLanguages: [String] { didSet { defaults.set(ocrLanguages, forKey: "ocrLanguages") } }
    /// Accurate recognition is preferred; fast mode is available for latency-sensitive captures.
    public var accurateOCR: Bool { didSet { defaults.set(accurateOCR, forKey: "accurateOCR") } }
    /// Translates an OCR result automatically with the selected provider.
    public var automaticTranslation: Bool { didSet { defaults.set(automaticTranslation, forKey: "automaticTranslation") } }
    /// Single selected translation service; failures never select another service.
    public var translationProvider: TranslationProviderID { didSet { defaults.set(translationProvider.rawValue, forKey: "translationProvider") } }
    /// REST templates contain no credentials; each key lives in the system Keychain.
    public var customTranslationServices: [CustomRESTConfiguration] {
        didSet { if let data = try? JSONEncoder().encode(customTranslationServices) { defaults.set(data, forKey: "customTranslationServices") } }
    }
    /// The instance used when the selected service is custom REST.
    public var selectedCustomTranslationID: UUID? { didSet { defaults.set(selectedCustomTranslationID?.uuidString, forKey: "selectedCustomTranslationID") } }
    /// Requested recording frame rate.
    public var recordingFPS: Int { didSet { defaults.set(recordingFPS, forKey: "recordingFPS") } }
    /// AVFoundation codec identifier: hevc or h264.
    public var recordingCodec: String { didSet { defaults.set(recordingCodec, forKey: "recordingCodec") } }
    /// Resolution-scaled recording bitrate quality, from zero to one.
    public var recordingQuality: Double { didSet { defaults.set(recordingQuality, forKey: "recordingQuality") } }
    /// Enables camera preview and video compositing only for an active recording.
    public var recordingCamera: Bool { didSet { defaults.set(recordingCamera, forKey: "recordingCamera") } }
    /// Maximum GIF output width in pixels.
    public var gifWidth: Int { didSet { defaults.set(gifWidth, forKey: "gifWidth") } }
    /// GIF sampling frames per second.
    public var gifFPS: Int { didSet { defaults.set(gifFPS, forKey: "gifFPS") } }
    /// Includes system sound in a recording.
    public var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: "systemAudio") } }
    /// Includes microphone audio only when explicitly enabled.
    public var microphone: Bool { didSet { defaults.set(microphone, forKey: "microphone") } }
    /// Includes the pointer in recordings; static screenshots omit it.
    public var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "showsCursor") } }
    /// History retention in days; zero keeps captures until deleted.
    public var historyRetention: Int { didSet { defaults.set(historyRetention, forKey: "historyRetention") } }
    /// 仅用于长截图兼容对照，下次会话生效；默认使用单帧精确行引擎。
    public var useLegacyScrollEngine: Bool { didSet { defaults.set(useLegacyScrollEngine, forKey: "useLegacyScrollEngine") } }

    /// Loads preferences from an injectable defaults store without storing any credentials.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "captureDelay": 0, "showsPixels": true, "exportFormat": "png", "jpegQuality": 0.9,
            "filenameTemplate": "niko-shot {date} {time}", "autoOCR": true, "automaticTranslation": true,
            "recordingFPS": 30, "recordingCodec": "hevc", "systemAudio": true,
            "microphone": false, "showsCursor": true, "historyRetention": 30, "accurateOCR": true,
            "useLegacyScrollEngine": false
        ])
        captureDelay = min(10, max(0, defaults.integer(forKey: "captureDelay")))
        showsPixels = defaults.bool(forKey: "showsPixels")
        if let data = defaults.data(forKey: "presetSizes"),
           let decoded = try? JSONDecoder().decode([CaptureSizePreset].self, from: data) {
            presetSizes = decoded.filter { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
        } else {
            presetSizes = [
                CaptureSizePreset(name: "Full HD", width: 1920, height: 1080),
                CaptureSizePreset(name: "HD", width: 1280, height: 720),
                CaptureSizePreset(name: "正方形", width: 1080, height: 1080)
            ]
        }
        let format = defaults.string(forKey: "exportFormat") ?? "png"
        exportFormatRaw = ["png", "jpeg", "heif", "tiff"].contains(format) ? format : "png"
        jpegQuality = min(1, max(0, defaults.double(forKey: "jpegQuality")))
        filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? "niko-shot {date} {time}"
        autoOCR = defaults.bool(forKey: "autoOCR")
        ocrLanguages = defaults.stringArray(forKey: "ocrLanguages") ?? ["zh-Hans", "en-US", "ja-JP"]
        accurateOCR = defaults.bool(forKey: "accurateOCR")
        automaticTranslation = defaults.bool(forKey: "automaticTranslation")
        translationProvider = TranslationProviderID(rawValue: defaults.string(forKey: "translationProvider") ?? "baidu") ?? .baidu
        customTranslationServices = defaults.data(forKey: "customTranslationServices").flatMap { try? JSONDecoder().decode([CustomRESTConfiguration].self, from: $0) } ?? []
        selectedCustomTranslationID = defaults.string(forKey: "selectedCustomTranslationID").flatMap(UUID.init(uuidString:))
        let fps = defaults.integer(forKey: "recordingFPS")
        recordingFPS = [15, 24, 30, 60].contains(fps) ? fps : 30
        recordingCodec = defaults.string(forKey: "recordingCodec") == "h264" ? "h264" : "hevc"
        recordingQuality = defaults.object(forKey: "recordingQuality") == nil ? 0.65 : min(1, max(0, defaults.double(forKey: "recordingQuality")))
        recordingCamera = defaults.bool(forKey: "recordingCamera")
        gifWidth = defaults.object(forKey: "gifWidth") == nil ? 800 : min(4096, max(64, defaults.integer(forKey: "gifWidth")))
        let gifRate = defaults.integer(forKey: "gifFPS")
        gifFPS = [5, 10, 15, 24, 30].contains(gifRate) ? gifRate : 15
        systemAudio = defaults.bool(forKey: "systemAudio")
        microphone = defaults.bool(forKey: "microphone")
        showsCursor = defaults.bool(forKey: "showsCursor")
        historyRetention = max(0, defaults.integer(forKey: "historyRetention"))
        useLegacyScrollEngine = defaults.bool(forKey: "useLegacyScrollEngine")
    }
}
