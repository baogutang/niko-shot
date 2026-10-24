// Publishes PNG and file URLs as data; native drag promises are supplied by DragExporter.
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
    /// for them would run on the main thread. TIFF readers get the pasteboard's own PNG conversion, so
    /// `image` is not kept: a crop holds its whole full-screen buffer (about 59 MB at 5K) alive.
    static func write(png: Data, image _: CGImage, date: Date, file: URL?, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        var objects: [any NSPasteboardWriting] = [item]
        var payload: CapturePasteboardPayload?
        if let file {
            item.setString(file.absoluteString, forType: .fileURL)
            let promise = CapturePasteboardPayload(file: file)
            objects.append(NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promise))
            payload = promise
        }
        pasteboard.clearContents(); pasteboard.writeObjects(objects)
        current = payload
    }
}

/// Writes the copy a pasted file promise asks for, off the main thread.
final class CapturePasteboardPayload: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let file: URL
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(file: URL) { self.file = file }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file.lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        do { try FileManager.default.copyItem(at: file, to: url); completionHandler(nil) } catch { completionHandler(error) }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }
}
