// Uses NSFilePromiseProvider to deliver native files to Finder and other drag destinations.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let source: URL
    init(source: URL) { self.source = source }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { source.lastPathComponent }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do { try FileManager.default.copyItem(at: source, to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

@MainActor
final class FileDragView: NSImageView {
    var source: URL?
    private var promiseDelegate: FilePromiseDelegate?
    override func mouseDragged(with event: NSEvent) {
        guard let source, let image else { return }
        let delegate = FilePromiseDelegate(source: source)
        promiseDelegate = delegate
        let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: source.pathExtension)?.identifier ?? UTType.png.identifier, delegate: delegate)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

extension FileDragView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { promiseDelegate = nil }
}

struct FileDragPreview: NSViewRepresentable {
    let url: URL
    let image: NSImage
    func makeNSView(context: Context) -> FileDragView { let view = FileDragView(); view.imageScaling = .scaleProportionallyUpOrDown; view.setAccessibilityLabel("拖出截图文件"); return view }
    func updateNSView(_ view: FileDragView, context: Context) { view.source = url; view.image = image }
}
