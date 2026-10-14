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
    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityLabel("拖出截图文件")
        return view
    }
    // 原图的 intrinsic size 不能覆盖缩略图的尺寸，否则最近截图只露出放大后的中间一块。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileDragView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateNSView(_ view: FileDragView, context: Context) { view.source = url; view.image = image }
}
