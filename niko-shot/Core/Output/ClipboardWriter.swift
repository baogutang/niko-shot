// Publishes multi-type images and file URLs; native drag promises are supplied by DragExporter.
import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipboardWriter {
    private static var current: CapturePasteboardPayload?
    private static var reserved: (capture: UUID, changeCount: Int)?

    /// Marks, at the click, the capture the clipboard is waiting for and what the clipboard held then.
    static func reserve(_ capture: UUID, on pasteboard: NSPasteboard = .general) {
        reserved = (capture, pasteboard.changeCount)
    }

    /// Publishes a reserved capture once its PNG exists, unless a newer capture was reserved or
    /// something else was copied in the meantime. Returns whether the clipboard now holds it.
    @discardableResult
    static func publish(_ capture: UUID, png: Data, image: CGImage, date: Date, file: URL?,
                        on pasteboard: NSPasteboard = .general) -> Bool {
        guard let reserved, reserved.capture == capture, reserved.changeCount == pasteboard.changeCount else { return false }
        self.reserved = nil
        write(png: png, image: image, date: date, file: file, to: pasteboard)
        return true
    }

    /// Writes PNG and the archived file URL as data, never as promises: input methods, clipboard
    /// tools and security agents read every new clipboard within a millisecond, and a provider asked
    /// for them would run on the main thread. Only TIFF (60 MB at 5K, rarely wanted) is drawn on request.
    static func write(png: Data, image: CGImage, date: Date, file: URL?, to pasteboard: NSPasteboard = .general) {
        let payload = CapturePasteboardPayload(image: image, date: date, file: file)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(payload, forTypes: [.tiff])
        var objects: [any NSPasteboardWriting] = [item]
        if let file {
            item.setString(file.absoluteString, forType: .fileURL)
            objects.append(NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: payload))
        }
        pasteboard.clearContents(); pasteboard.writeObjects(objects)
        current = payload
    }
}

/// The parts of a published capture made only when asked: TIFF, and the copy a file promise writes.
final class CapturePasteboardPayload: NSObject, NSPasteboardItemDataProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let file: URL?
    private let image: CGImage
    private let date: Date
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(image: CGImage, date: Date, file: URL?) {
        self.image = image; self.date = date; self.file = file
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let data = try? Exporters.encode(image, format: .tiff, date: date) else { return }
        item.setData(data, forType: .tiff)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file?.lastPathComponent ?? "niko-shot.png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        guard let file else { completionHandler(AppError.file("截图未能保存。")); return }
        do { try FileManager.default.copyItem(at: file, to: url); completionHandler(nil) } catch { completionHandler(error) }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }
}
