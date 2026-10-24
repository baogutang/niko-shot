// Drags an archived capture out as a real file URL plus PNG data, under a readable name instead of its UUID.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DragExport {
    /// "niko-shot 2026-10-24 13.05.12.png": the name a dropped capture lands under.
    static func fileName(for date: Date, pathExtension: String = "png") -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "niko-shot " + formatter.string(from: date) + "." + (pathExtension.isEmpty ? "png" : pathExtension)
    }

    static var stagingRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-drag", isDirectory: true) }

    /// Clones the archive under its readable name into a folder of its own; on APFS the clone is instant.
    /// The copy outlives the drop because Terminal pastes its path and uploaders read it later.
    static func stagedFile(for source: URL, date: Date?, in root: URL = stagingRoot) throws -> URL {
        let created = date ?? (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
        let folder = root.appendingPathComponent(source.deletingPathExtension().lastPathComponent, isDirectory: true)
        let target = folder.appendingPathComponent(fileName(for: created, pathExtension: source.pathExtension))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// The file URL serves Finder, Terminal and web upload areas; PNG serves targets that take only images.
    /// Both are plain data: the file already exists, so nothing is encoded or promised on the main thread.
    static func pasteboardItem(for file: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .png) == true,
           let png = try? Data(contentsOf: file, options: .mappedIfSafe) { item.setData(png, forType: .png) }
        return item
    }

    @MainActor static func draggingItem(for source: URL, date: Date?, frame: CGRect, image: NSImage) -> NSDraggingItem {
        let file = (try? stagedFile(for: source, date: date)) ?? source
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: file))
        item.setDraggingFrame(frame, contents: image)
        return item
    }
}

@MainActor
final class FileDragView: NSImageView {
    var source: URL?
    var date: Date?
    override func mouseDragged(with event: NSEvent) {
        guard let source, let image else { return }
        beginDraggingSession(with: [DragExport.draggingItem(for: source, date: date, frame: bounds, image: image)], event: event, source: self)
    }
}

extension FileDragView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

struct FileDragPreview: NSViewRepresentable {
    let url: URL
    let image: NSImage
    /// Capture time for the dragged file's name; without it the file's creation date is used.
    var date: Date? = nil
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
    func updateNSView(_ view: FileDragView, context: Context) { view.source = url; view.date = date; view.image = image }
}
