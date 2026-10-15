// Publishes multi-type images and file URLs; native drag promises are supplied by DragExporter.
import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipboardWriter {
    private static var current: DeferredCapturePayload?

    /// Claims the clipboard at once: PNG and TIFF are encoded when a paste asks for them, and the
    /// archived file URL follows as soon as the capture is saved. A paste never waits for history.
    static func write(_ payload: DeferredCapturePayload) {
        let item = NSPasteboardItem()
        item.setDataProvider(payload, forTypes: [.png, .tiff, .fileURL])
        let promise = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: payload)
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item, promise])
        current = payload
    }
}

/// One capture promised to the pasteboard before it is encoded and archived.
final class DeferredCapturePayload: NSObject, NSPasteboardItemDataProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let file: URL
    private let image: CGImage
    private let date: Date
    // Guards `png`, `saved` and `failed`; providers are asked on the main thread while archiving runs elsewhere.
    private let condition = NSCondition()
    private var png: Data?
    private var saved = false
    private var failed = false
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(image: CGImage, date: Date, file: URL) {
        self.image = image; self.date = date; self.file = file
    }

    /// The PNG has been encoded and `file` exists.
    func fulfill(png data: Data) {
        condition.lock(); png = data; saved = true; condition.broadcast(); condition.unlock()
    }

    /// Archiving failed: images still paste, but no file URL is offered.
    func fail() {
        condition.lock(); failed = true; condition.broadcast(); condition.unlock()
    }

    private func waitUntilSaved(timeout: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !saved && !failed { if !condition.wait(until: deadline) { break } }
        return saved
    }

    private var encodedPNG: Data? {
        condition.lock(); let cached = png; condition.unlock()
        return cached ?? (try? Exporters.encode(image, format: .png, date: date))
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            if let data = encodedPNG { item.setData(data, forType: .png) }
        case .tiff:
            if let data = try? Exporters.encode(image, format: .tiff, date: date) { item.setData(data, forType: .tiff) }
        case .fileURL:
            if waitUntilSaved(timeout: 3) { item.setString(file.absoluteString, forType: .fileURL) }
        default:
            break
        }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file.lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        guard waitUntilSaved(timeout: 10) else { completionHandler(AppError.file("截图尚未保存完成。")); return }
        do { try FileManager.default.copyItem(at: file, to: url); completionHandler(nil) } catch { completionHandler(error) }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }
}
