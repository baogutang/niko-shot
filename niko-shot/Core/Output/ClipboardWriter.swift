// Publishes multi-type images and file URLs; native drag promises are supplied by DragExporter.
import AppKit

@MainActor
enum ClipboardWriter {
    private static var promiseDelegate: FilePromiseDelegate?
    /// Writes PNG, TIFF and an existing file URL as one clipboard item for compatible paste targets.
    static func write(png: Data, tiff: Data, file: URL) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png); item.setData(tiff, forType: .tiff)
        item.setString(file.absoluteString, forType: .fileURL)
        let delegate = FilePromiseDelegate(source: file)
        promiseDelegate = delegate
        let promise = NSFilePromiseProvider(fileType: "public.png", delegate: delegate)
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item, promise])
    }
}
