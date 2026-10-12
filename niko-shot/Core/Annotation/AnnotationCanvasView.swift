// Shares mouse and keyboard gestures, native text input and cancellable previews over one vector document.
import AppKit
import CoreText

@MainActor
final class AnnotationCanvasView: NSView {
    let base: CGImage
    var document: AnnotationDocument {
        didSet { onDocumentChange?(); updateAccessibility() }
    }
    var tool: AnnotationTool = .rectangle {
        didSet {
            guard oldValue != tool else { return }
            clearPending()
            window?.invalidateCursorRects(for: self)
            onToolChange?(tool)
            updateAccessibility()
        }
    }
    var color = AnnotationColor.red
    var strokeWidth: CGFloat = 3
    var onAction: ((ToolbarAction) -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var onDocumentChange: (() -> Void)?
    private var pending: AnnotationItem?
    private var keyboardEndpoint: CGPoint?
    private let gesture = CAShapeLayer()
    private var revision = 0
    private var previewTasks: [Int: Task<Void, Never>] = [:]
    private var textAlert: NSAlert?
    private var isFinishing = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Live input UI and render tasks, including canceled previews until their workers finish.
    var resourceCounts: [String: Int] {
        ["pendingGesture": pending == nil ? 0 : 1, "preview": previewTasks.count,
         "textAlert": textAlert == nil ? 0 : 1]
    }

    init(image: CGImage, size: CGSize) {
        base = image; document = AnnotationDocument(canvasSize: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.contents = image; layer?.contentsGravity = .resize
        gesture.fillColor = NSColor.clear.cgColor; gesture.lineCap = .round; gesture.lineJoin = .round
        layer?.addSublayer(gesture)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("标注画布")
        setAccessibilityHelp("数字 1 到 9 选工具，左右方括号循环全部工具。空格在画布中心开始或完成标注，方向键移动端点 1 个原图像素，Shift 加方向键移动 10 像素。文字和便签用空格打开文字输入。Tab 返回框选，Enter 复制，Escape 退出，Command S 保存，Command Z 撤销。")
        updateAccessibility()
    }
    required init?(coder: NSCoder) { return nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text || tool == .note ? .iBeam : .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        window?.makeFirstResponder(self)
        beginGesture(at: convert(event.locationInWindow, from: nil), keyboard: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinishing, keyboardEndpoint == nil else { return }
        updateGesture(to: convert(event.locationInWindow, from: nil),
            aspect: event.modifierFlags.contains(.shift) ? 1 : nil,
            centered: event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        guard !isFinishing, keyboardEndpoint == nil else { return }
        finishGesture()
    }

    private func beginGesture(at point: CGPoint, keyboard: Bool) {
        clearPending()
        var item = AnnotationItem(tool: tool, color: color, width: strokeWidth,
            rect: CGRect(origin: point, size: .zero), points: [point])
        if tool == .text || tool == .note { addNativeText(to: item); return }
        if tool == .step {
            item.rect = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
            item.number = document.commands.filter { $0.tool == .step }.count + 1
            document.append(item); refresh(); return
        }
        pending = item
        keyboardEndpoint = keyboard ? point : nil
        updateAccessibility()
    }

    private func addNativeText(to initial: AnnotationItem) {
        guard !isFinishing, textAlert == nil else { return }
        var item = initial
        let point = item.rect.origin
        let alert = NSAlert(); alert.messageText = item.tool.title
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 110))
        let textView = NSTextView(frame: scroll.bounds); textView.font = .systemFont(ofSize: 18); textView.isRichText = false
        textView.setAccessibilityLabel("\(item.tool.title)内容")
        scroll.documentView = textView; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = textView
        textAlert = alert
        defer {
            if textAlert === alert { textAlert = nil }
            updateAccessibility()
        }
        let response = alert.runModal()
        guard !isFinishing, response == .alertFirstButtonReturn, !textView.string.isEmpty else { return }
        item.text = textView.string
        let font = textView.font ?? .systemFont(ofSize: 18)
        item.font = FontSnapshot(postScriptName: font.fontName, pointSize: font.pointSize)
        item.rect.size = CGSize(width: min(320, bounds.maxX - point.x), height: min(180, bounds.maxY - point.y))
        document.append(item); refresh()
    }

    private func updateGesture(to point: CGPoint, aspect: CGFloat? = nil, centered: Bool = false) {
        guard var item = pending, let first = item.points.first else { return }
        if [.pen, .mosaic, .blur].contains(item.tool) { item.points.append(point) }
        else { item.points = [first, point] }
        item.rect = SelectionGeometry.drag(anchor: first, point: point, aspect: aspect, centered: centered)
        pending = item
        let path = CGMutablePath()
        if [.rectangle, .highlight, .mosaic, .blur].contains(item.tool), item.points.count <= 2 { path.addRect(item.rect) }
        else if item.tool == .ellipse || item.tool == .magnifier { path.addEllipse(in: item.rect) }
        else { path.move(to: first); for point in item.points.dropFirst() { path.addLine(to: point) } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gesture.strokeColor = item.color.cgColor; gesture.lineWidth = item.width; gesture.path = path
        CATransaction.commit()
        if keyboardEndpoint != nil { updateAccessibility() }
    }

    private func finishGesture() {
        if let pending, pending.points.count > 1 { document.append(pending); refresh() }
        clearPending()
    }

    private func clearPending() {
        pending = nil; keyboardEndpoint = nil; gesture.path = nil
        updateAccessibility()
    }

    /// Stops input and previews and dismisses this canvas's text modal before its owning session closes.
    func prepareForFinish() {
        isFinishing = true; revision += 1
        for task in previewTasks.values { task.cancel() }
        clearPending()
        let alert = textAlert; textAlert = nil
        if let alert {
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil); alert.window.close()
        }
    }

    /// Cancels input and awaits every current or superseded preview before the session releases this canvas.
    func finishAndDrain() async {
        prepareForFinish()
        let tasks = Array(previewTasks.values)
        for task in tasks { await task.value }
    }

    /// Rebuilds a committed preview with the same background renderer as the export path.
    func refresh() {
        guard !isFinishing else { return }
        revision += 1
        for task in previewTasks.values { task.cancel() }
        let currentRevision = revision, snapshot = document, image = base
        let scale = CGFloat(image.width) / max(1, snapshot.canvasSize.width)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rendered = try AnnotationRenderer.render(base: image, document: snapshot, scale: scale)
            try Task.checkCancellation()
            return rendered
        }
        previewTasks[currentRevision] = Task { [weak self] in
            defer { self?.previewTasks[currentRevision] = nil }
            do {
                let rendered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, !self.isFinishing, self.revision == currentRevision else { return }
                self.layer?.contents = rendered
            } catch is CancellationError {}
            catch {
                guard let self, !self.isFinishing, self.revision == currentRevision, !Task.isCancelled else { return }
                ErrorPresenter.show(error)
            }
        }
    }

    func undo() { guard !isFinishing else { return }; clearPending(); document.undo(); refresh() }
    func redo() { guard !isFinishing else { return }; clearPending(); document.redo(); refresh() }

    private func cycleTool(_ direction: Int) {
        let tools = AnnotationTool.allCases
        guard let index = tools.firstIndex(of: tool), !tools.isEmpty else { return }
        tool = tools[(index + direction + tools.count) % tools.count]
    }

    private func moveKeyboardEndpoint(keyCode: UInt16, accelerated: Bool) -> Bool {
        guard var point = keyboardEndpoint, pending != nil else { return false }
        let pixels: CGFloat = accelerated ? 10 : 1
        let dx = document.canvasSize.width / CGFloat(base.width) * pixels
        let dy = document.canvasSize.height / CGFloat(base.height) * pixels
        switch keyCode {
        case 123: point.x -= dx
        case 124: point.x += dx
        case 125: point.y += dy
        case 126: point.y -= dy
        default: return false
        }
        point.x = min(bounds.maxX, max(bounds.minX, point.x))
        point.y = min(bounds.maxY, max(bounds.minY, point.y))
        keyboardEndpoint = point
        // Shift accelerates keyboard pixel steps; mouse-only aspect/center constraints remain independent.
        updateGesture(to: point)
        return true
    }

    private func updateAccessibility() {
        let status = isFinishing ? "标注已结束" : keyboardEndpoint == nil ? "空格开始标注" : "正在放置，方向键移动端点，空格完成"
        setAccessibilityValue("当前工具：\(tool.title)，已有 \(document.commands.count) 条标注。\(status)。")
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func keyDown(with event: NSEvent) {
        guard !isFinishing else { return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "z" { if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return }
            if key == "s" { finishGesture(); onAction?(.save); return }
        }
        if let number = Int(key), (1...9).contains(number) { tool = AnnotationTool.allCases[number - 1]; return }
        if key == "[" || event.keyCode == 33 { cycleTool(-1); return }
        if key == "]" || event.keyCode == 30 { cycleTool(1); return }
        if moveKeyboardEndpoint(keyCode: event.keyCode, accelerated: event.modifierFlags.contains(.shift)) { return }
        switch event.keyCode {
        case 49:
            if keyboardEndpoint != nil { finishGesture() }
            else { beginGesture(at: CGPoint(x: bounds.midX, y: bounds.midY), keyboard: true) }
        case 36, 76: finishGesture(); onAction?(.copy)
        case 53: clearPending(); onAction?(.close)
        case 48: clearPending(); onAction?(.selection)
        default: super.keyDown(with: event)
        }
    }
}

final class AnnotationStageView: NSView {
    override var isFlipped: Bool { true }
}
