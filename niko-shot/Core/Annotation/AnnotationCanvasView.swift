// Renders an immutable crop with a live vector gesture layer and asynchronous committed annotations.
import AppKit
import CoreText

@MainActor
final class AnnotationCanvasView: NSView {
    let base: CGImage
    var document: AnnotationDocument { didSet { onDocumentChange?() } }
    var tool: AnnotationTool = .rectangle { didSet { window?.invalidateCursorRects(for: self); onToolChange?(tool) } }
    var color = AnnotationColor.red
    var strokeWidth: CGFloat = 3
    var onAction: ((ToolbarAction) -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var onDocumentChange: (() -> Void)?
    private var pending: AnnotationItem?
    private let gesture = CAShapeLayer()
    private var revision = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, size: CGSize) {
        base = image; document = AnnotationDocument(canvasSize: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.contents = image; layer?.contentsGravity = .resize
        gesture.fillColor = NSColor.clear.cgColor; gesture.lineCap = .round; gesture.lineJoin = .round
        layer?.addSublayer(gesture)
        setAccessibilityElement(true); setAccessibilityLabel("标注画布，数字 1 到 9 切工具，Tab 返回框选，Command S 保存")
    }
    required init?(coder: NSCoder) { return nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text || tool == .note ? .iBeam : .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        var item = AnnotationItem(tool: tool, color: color, width: strokeWidth, rect: CGRect(origin: point, size: .zero), points: [point])
        if tool == .text || tool == .note {
            let alert = NSAlert(); alert.messageText = tool.title
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 110))
            let textView = NSTextView(frame: scroll.bounds); textView.font = .systemFont(ofSize: 18); textView.isRichText = false
            scroll.documentView = textView; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = textView
            if alert.runModal() == .alertFirstButtonReturn, !textView.string.isEmpty {
                item.text = textView.string
                let font = textView.font ?? .systemFont(ofSize: 18)
                item.font = FontSnapshot(postScriptName: font.fontName, pointSize: font.pointSize)
                item.rect.size = CGSize(width: min(320, bounds.maxX - point.x), height: min(180, bounds.maxY - point.y))
                document.append(item); refresh()
            }
            return
        }
        if tool == .step {
            item.rect = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
            item.number = document.commands.filter { $0.tool == .step }.count + 1
            document.append(item); refresh(); return
        }
        pending = item
    }
    override func mouseDragged(with event: NSEvent) {
        guard var item = pending, let first = item.points.first else { return }
        let point = convert(event.locationInWindow, from: nil)
        if [.pen, .mosaic, .blur].contains(tool) { item.points.append(point) }
        else { item.points = [first, point] }
        item.rect = SelectionGeometry.drag(anchor: first, point: point, aspect: event.modifierFlags.contains(.shift) ? 1 : nil, centered: event.modifierFlags.contains(.option))
        pending = item
        let path = CGMutablePath()
        if [.rectangle, .highlight, .mosaic, .blur].contains(tool), item.points.count <= 2 { path.addRect(item.rect) }
        else if tool == .ellipse || tool == .magnifier { path.addEllipse(in: item.rect) }
        else { path.move(to: first); for point in item.points.dropFirst() { path.addLine(to: point) } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gesture.strokeColor = item.color.cgColor; gesture.lineWidth = item.width; gesture.path = path
        CATransaction.commit()
    }
    override func mouseUp(with event: NSEvent) {
        if let pending, pending.points.count > 1 { document.append(pending); refresh() }
        pending = nil; gesture.path = nil
    }
    /// Rebuilds a committed preview with the same renderer as the export path.
    func refresh() {
        revision += 1
        let currentRevision = revision, snapshot = document, image = base
        let scale = CGFloat(image.width) / max(1, snapshot.canvasSize.width)
        Task { [weak self] in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) { try AnnotationRenderer.render(base: image, document: snapshot, scale: scale) }.value
                guard let self, self.revision == currentRevision else { return }
                self.layer?.contents = rendered
            } catch { ErrorPresenter.show(error) }
        }
    }
    func undo() { document.undo(); refresh() }
    func redo() { document.redo(); refresh() }
    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "z" { if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return }
            if key == "s" { onAction?(.save); return }
        }
        if let number = Int(key), (1...9).contains(number) { tool = AnnotationTool.allCases[number - 1]; return }
        switch event.keyCode { case 36, 76: onAction?(.copy); case 53: onAction?(.close); case 48: onAction?(.selection); default: super.keyDown(with: event) }
    }
}

final class AnnotationStageView: NSView {
    override var isFlipped: Bool { true }
}
