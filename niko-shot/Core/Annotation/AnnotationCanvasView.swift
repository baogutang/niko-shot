// Interactive annotation canvas: draw, select, move, resize, restyle and edit text inline over the capture.
import AppKit
import CoreText

@MainActor
final class AnnotationCanvasView: NSView {
    let base: CGImage
    let effects: AnnotationEffects
    var document: AnnotationDocument {
        didSet {
            if let selectedID, document.item(id: selectedID) == nil { select(nil) }
            refresh()
            onDocumentChange?(); updateAccessibility()
        }
    }
    var tool: AnnotationTool = .rectangle {
        didSet {
            guard oldValue != tool else { return }
            let wasSyncing = syncingStyle
            syncingStyle = true
            if tool.isTextual { style.textBackground = tool == .note }
            if tool.isEffect { style.blur = tool == .blur }
            syncingStyle = wasSyncing
            if !tool.isTextual { commitTextEditing() }
            clearPending()
            window?.invalidateCursorRects(for: self)
            onToolChange?(tool)
            updateAccessibility()
        }
    }
    /// Drawing style for new items; changes also restyle the selected item as one undoable step.
    var style = AnnotationStyle() {
        didSet {
            guard style != oldValue else { return }
            if tool.isEffect { tool = style.blur ? .blur : .mosaic }
            if tool.isTextual { tool = style.textBackground ? .note : .text }
            if !syncingStyle { applyStyleToSelection() }
            textEditor?.apply(style: style, tool: tool)
        }
    }
    var color: AnnotationColor { get { style.color } set { style.color = newValue } }
    var strokeWidth: CGFloat { get { style.width } set { style.width = newValue } }
    var onAction: ((ToolbarAction) -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var onDocumentChange: (() -> Void)?
    /// Reports the selected item so the property bar can show controls for its kind.
    var onSelectionChange: ((AnnotationItem?) -> Void)?
    /// Reports style adopted from a selected item (or a wheel resize) so the property bar mirrors it.
    var onStyleChange: ((AnnotationStyle) -> Void)?

    private(set) var selectedID: UUID?
    private var pending: AnnotationItem?
    /// Transient geometry while an existing item is moved or resized; committed on mouse-up.
    private var editing: AnnotationItem?
    private var drag: Drag?
    private var keyboardEndpoint: CGPoint?
    private var syncingStyle = false
    private var isFinishing = false
    private var previewJobs: [UUID: Task<CGImage, Error>] = [:]
    private var previewGeneration = UUID()
    private var requestedPreview: [AnnotationItem] = []
    fileprivate private(set) var renderedPreview: CGImage?
    private var textEditor: AnnotationTextEditor?
    private var hiddenItemID: UUID?
    /// The item last changed by a repeatable gesture; repeats within a second extend that undo step.
    private var amendable: (id: UUID, at: Date)?
    private let overlay = AnnotationOverlayView()
    private var tracking: NSTrackingArea?

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(start: CGPoint, original: AnnotationItem)
        case resizing(handle: Int, original: AnnotationItem)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var resourceCounts: [String: Int] {
        ["pendingGesture": pending == nil ? 0 : 1, "preview": previewJobs.count, "textAlert": textEditor == nil ? 0 : 1]
    }
    var isEditingText: Bool { textEditor != nil }

    init(image: CGImage, size: CGSize) {
        base = image
        document = AnnotationDocument(canvasSize: size)
        effects = AnnotationEffects(base: image, canvasSize: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("标注画布")
        setAccessibilityHelp("数字 1 到 9 选择工具，方括号循环工具。方向键每次移动一个原图像素，Shift 加速。单击已画的标注可选中、拖动、按 Delete 删除。空格在中心开始或完成标注，方向键移动端点。Tab 调整选区，Enter 完成，Escape 退出，Command S 保存，Command Z 撤销。")
        updateAccessibility()
    }
    required init?(coder: NSCoder) { return nil }

    // MARK: - Public API

    func refresh() {
        overlay.needsDisplay = true
        guard !isFinishing else { return }
        let items = renderSplit.rendered
        guard items != requestedPreview else { return }
        requestedPreview = items
        previewGeneration = UUID()
        for job in previewJobs.values { job.cancel() }
        guard !items.isEmpty else {
            renderedPreview = nil
            return
        }
        let token = previewGeneration, base = base
        var snapshot = document
        snapshot = AnnotationDocument(canvasSize: document.canvasSize)
        for item in items { snapshot.append(item) }
        let scale = CGFloat(base.width) / max(1, document.canvasSize.width)
        let job = Task.detached(priority: .userInitiated) { try AnnotationRenderer.render(base: base, document: snapshot, scale: scale) }
        previewJobs[token] = job
        Task { [weak self] in
            let image = try? await job.value
            guard let self else { return }
            self.previewJobs[token] = nil
            guard !self.isFinishing, self.previewGeneration == token else { return }
            self.renderedPreview = image
            self.overlay.needsDisplay = true
        }
    }
    func undo() { guard !isFinishing else { return }; amendable = nil; commitTextEditing(); clearPending(); document.undo(); refresh() }
    func redo() { guard !isFinishing else { return }; amendable = nil; commitTextEditing(); clearPending(); document.redo(); refresh() }
    func clearAll() { guard !isFinishing else { return }; commitTextEditing(); clearPending(); select(nil); document.removeAll() }

    /// Commits inline text and in-flight gestures before export or OCR.
    func commitPendingEdits() {
        commitTextEditing()
        if case .drawing = drag { finishDrawing() }
        else if keyboardEndpoint != nil { finishDrawing(); keyboardEndpoint = nil }
        if let editing { commit(editing) }
        drag = nil; editing = nil
    }

    /// Stops input and removes the inline editor before the owning session closes.
    func prepareForFinish() {
        isFinishing = true
        for job in previewJobs.values { job.cancel() }
        renderedPreview = nil
        clearPending()
        textEditor?.removeFromSuperview(); textEditor = nil; hiddenItemID = nil
    }

    func finishAndDrain() async {
        prepareForFinish()
        let jobs = Array(previewJobs.values)
        for job in jobs { _ = try? await job.value }
        previewJobs.removeAll()
    }

    // MARK: - Drawing support for the overlay

    /// Marks up to the last filter-like one (which samples what lies below it) need the background renderer;
    /// everything after it, including the mark being drawn, is drawn live so dragging never waits for a render.
    fileprivate var renderSplit: (rendered: [AnnotationItem], live: [AnnotationItem]) {
        let items = visibleItems
        guard let last = items.lastIndex(where: { $0.tool.needsRenderedPreview }) else { return ([], items) }
        return (Array(items[...last]), Array(items[(last + 1)...]))
    }

    fileprivate var visibleItems: [AnnotationItem] {
        var items = document.commands.filter { $0.id != hiddenItemID }
        if let editing, let index = items.firstIndex(where: { $0.id == editing.id }) { items[index] = editing }
        if let pending { items.append(pending) }
        return items
    }

    fileprivate var selectionChrome: (bounds: CGRect, handles: [CGPoint])? {
        guard let selectedID, hiddenItemID != selectedID,
              let item = editing?.id == selectedID ? editing : document.item(id: selectedID) else { return nil }
        return (item.bounds.insetBy(dx: -4, dy: -4), Self.handles(for: item))
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool.isTextual ? .iBeam : .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let selectedID, let item = document.item(id: selectedID), let handle = Self.handleIndex(at: point, for: item) {
            Self.cursor(forHandle: handle, item: item).set()
        } else if hitItem(at: point) != nil {
            NSCursor.openHand.set()
        } else {
            (tool.isTextual ? NSCursor.iBeam : NSCursor.crosshair).set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        if textEditor != nil {
            // 点击编辑框外先结束输入，不在同一次点击里再画新标注。
            commitTextEditing(); window?.makeFirstResponder(self); return
        }
        window?.makeFirstResponder(self)
        keyboardEndpoint = nil
        amendable = nil
        if let selectedID, let item = document.item(id: selectedID), let handle = Self.handleIndex(at: point, for: item) {
            drag = .resizing(handle: handle, original: item); editing = item; return
        }
        if let hit = hitItem(at: point) {
            if event.clickCount >= 2, hit.tool.isTextual { beginTextEditing(existing: hit); return }
            select(hit.id)
            drag = .moving(start: point, original: hit); editing = hit
            NSCursor.closedHand.set()
            return
        }
        select(nil)
        if tool.isTextual { beginTextEditing(at: point); return }
        if tool == .step {
            let item = AnnotationItem(tool: .step, color: style.color, width: style.width,
                                      rect: CGRect(x: point.x, y: point.y, width: 0, height: 0), number: document.nextStepNumber)
            document.append(item)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }
        pending = newItem(at: point)
        drag = .drawing(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinishing, let drag else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        let constrained = event.modifierFlags.contains(.shift)
        switch drag {
        case .drawing(let start):
            guard var item = pending else { return }
            Self.update(&item, from: start, to: point, constrained: constrained, centered: event.modifierFlags.contains(.option))
            pending = item
        case .moving(let start, let original):
            var moved = original
            moved.translate(by: CGPoint(x: point.x - start.x, y: point.y - start.y))
            editing = moved
        case .resizing(let handle, let original):
            editing = Self.resize(original, handle: handle, to: point, constrained: constrained)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard !isFinishing, let drag else { return }
        self.drag = nil
        switch drag {
        case .drawing: finishDrawing()
        case .moving, .resizing:
            if let editing { commit(editing) }
            editing = nil
            refresh()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 规格：滚轮调整选中标注的尺寸（线宽、字号或序号大小）。
        guard !isFinishing, let selectedID, var item = document.item(id: selectedID) else { super.scrollWheel(with: event); return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        guard abs(delta) >= 0.5 else { return }
        let step: CGFloat = delta > 0 ? 1 : -1
        if item.tool.isTextual {
            item.font.pointSize = min(96, max(10, item.font.pointSize + step * 2))
            item.rect.size = textSize(for: item)
        } else {
            item.width = min(24, max(1, item.width + step))
        }
        commitCoalescing(item)
        syncStyle(from: item)
    }

    private func finishDrawing() {
        guard let item = pending else { return }
        pending = nil
        let size = item.bounds.size
        let meaningful: Bool
        switch item.tool {
        case .pen: meaningful = item.points.count > 1
        case .line, .arrow:
            meaningful = item.points.count == 2 && hypot(item.points[1].x - item.points[0].x, item.points[1].y - item.points[0].y) > 3
        default: meaningful = size.width > 3 && size.height > 3
        }
        guard meaningful else { refresh(); return }
        document.append(item)
        if item.tool != .pen { select(item.id) }
        refresh()
    }

    private func newItem(at point: CGPoint) -> AnnotationItem {
        AnnotationItem(tool: tool, color: style.color, width: style.width,
                       rect: CGRect(origin: point, size: .zero), points: [point], filled: tool.supportsFill && style.filled)
    }

    private func commit(_ item: AnnotationItem) {
        guard document.item(id: item.id) != nil else { return }
        amendable = nil
        document.replace(item)
    }

    private func commitCoalescing(_ item: AnnotationItem) {
        guard document.item(id: item.id) != nil else { return }
        let now = Date()
        if let amendable, amendable.id == item.id, now.timeIntervalSince(amendable.at) < 1, document.canUndo {
            document.amend(item)
        } else {
            document.replace(item)
        }
        amendable = (item.id, now)
    }

    private func clearPending() {
        pending = nil; keyboardEndpoint = nil; drag = nil; editing = nil
        refresh()
        updateAccessibility()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    // MARK: - Selection

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        refresh()
        let item = id.flatMap { document.item(id: $0) }
        if let item { syncStyle(from: item) }
        onSelectionChange?(item)
    }

    private func syncStyle(from item: AnnotationItem) {
        syncingStyle = true
        var next = style
        next.color = item.color
        if item.tool.isTextual { next.fontSize = item.font.pointSize; next.textBackground = item.tool == .note }
        else { next.width = item.width }
        if item.tool.supportsFill { next.filled = item.filled }
        if item.tool.isEffect { next.blur = item.tool == .blur }
        style = next
        syncingStyle = false
        onStyleChange?(style)
    }

    private func applyStyleToSelection() {
        guard let selectedID, var item = document.item(id: selectedID) else { return }
        item.color = style.color
        if item.tool.isTextual {
            item.font.pointSize = style.fontSize
            item.tool = style.textBackground ? .note : .text
            item.rect.size = textSize(for: item)
        } else if item.tool.isEffect {
            item.width = style.width
            item.tool = style.blur ? .blur : .mosaic
        } else {
            item.width = style.width
        }
        if item.tool.supportsFill { item.filled = style.filled }
        commit(item)
    }

    private func hitItem(at point: CGPoint) -> AnnotationItem? {
        for item in document.commands.reversed() where Self.hit(item, at: point) { return item }
        return nil
    }

    static func hit(_ item: AnnotationItem, at point: CGPoint) -> Bool {
        let tolerance = max(6, item.width / 2 + 4)
        switch item.tool {
        case .line, .arrow, .pen:
            let points = item.points
            guard points.count > 1 else { return false }
            for index in 1..<points.count where distance(point, toSegment: points[index - 1], points[index]) <= tolerance { return true }
            return false
        case .rectangle, .ellipse:
            let rect = item.rect.standardized
            if item.filled { return rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) }
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance), inner = rect.insetBy(dx: tolerance, dy: tolerance)
            if item.tool == .ellipse {
                let a = max(1, rect.width / 2), b = max(1, rect.height / 2)
                let dx = (point.x - rect.midX) / a, dy = (point.y - rect.midY) / b
                let normalized = sqrt(dx * dx + dy * dy)
                return abs(normalized - 1) * min(a, b) <= tolerance
            }
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        default:
            return item.bounds.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Endpoints for lines and arrows, eight handles for box-shaped items, none otherwise.
    static func handles(for item: AnnotationItem) -> [CGPoint] {
        switch item.tool {
        case .line, .arrow:
            guard let first = item.points.first, let last = item.points.last else { return [] }
            return [first, last]
        case .rectangle, .ellipse, .highlight, .mosaic, .blur, .magnifier:
            return SelectionGeometry.handles(item.rect.standardized)
        default:
            return []
        }
    }

    private static func handleIndex(at point: CGPoint, for item: AnnotationItem) -> Int? {
        handles(for: item).firstIndex { hypot($0.x - point.x, $0.y - point.y) <= 7 }
    }

    private static func cursor(forHandle handle: Int, item: AnnotationItem) -> NSCursor {
        item.tool.isLinear ? .crosshair : SelectionCursors.cursor(forHandle: handle)
    }

    // MARK: - Geometry

    static func update(_ item: inout AnnotationItem, from start: CGPoint, to point: CGPoint, constrained: Bool, centered: Bool) {
        switch item.tool {
        case .pen:
            if let last = item.points.last, hypot(point.x - last.x, point.y - last.y) < 1.2 { return }
            if constrained, let first = item.points.first { item.points = [first, snap(point, from: first)] }
            else { item.points.append(point) }
        case .line, .arrow:
            item.points = [start, constrained ? snap(point, from: start) : point]
        default:
            item.rect = SelectionGeometry.drag(anchor: start, point: point, aspect: constrained ? 1 : nil, centered: centered)
            item.points = [start, point]
        }
    }

    /// Snaps a direction to the nearest 45° for Shift-constrained lines.
    static func snap(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    static func resize(_ item: AnnotationItem, handle: Int, to point: CGPoint, constrained: Bool) -> AnnotationItem {
        var result = item
        if item.tool.isLinear {
            guard item.points.count == 2 else { return item }
            let anchor = item.points[handle == 0 ? 1 : 0]
            let moved = constrained ? snap(point, from: anchor) : point
            result.points[handle == 0 ? 0 : 1] = moved
            return result
        }
        let rect = item.rect.standardized
        result.rect = SelectionGeometry.resize(rect, handle: handle, to: point,
                                               aspect: constrained ? rect.width / max(1, rect.height) : nil, centered: false)
        return result
    }

    // MARK: - Text

    private func beginTextEditing(at point: CGPoint) {
        var item = AnnotationItem(tool: style.textBackground ? .note : .text, color: style.color, width: style.width,
                                  rect: CGRect(origin: point, size: .zero),
                                  font: FontSnapshot(postScriptName: FontSnapshot().postScriptName, pointSize: style.fontSize))
        let inset = AnnotationRenderer.textInset(for: item)
        item.rect.origin = CGPoint(x: max(0, point.x - inset.width), y: max(0, point.y - item.font.pointSize * 0.6 - inset.height))
        openEditor(for: item, isNew: true)
    }

    private func beginTextEditing(existing item: AnnotationItem) {
        select(item.id)
        openEditor(for: item, isNew: false)
    }

    private func openEditor(for item: AnnotationItem, isNew: Bool) {
        commitTextEditing()
        let editor = AnnotationTextEditor(item: item, isNew: isNew, maximumWidth: max(60, bounds.width - item.rect.minX - 4))
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        textEditor = editor
        hiddenItemID = isNew ? nil : item.id
        addSubview(editor)
        editor.layoutForText()
        window?.makeFirstResponder(editor.textView)
        refresh()
        updateAccessibility()
    }

    private func commitTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil; hiddenItemID = nil
        let text = editor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : editor.textView.string
        var item = editor.item
        item.text = text
        item.rect.size = textSize(for: item)
        editor.removeFromSuperview()
        if text.isEmpty {
            if !editor.isNew { document.remove(id: item.id) }
        } else if editor.isNew {
            document.append(item); select(item.id)
        } else {
            commit(item)
        }
        if window?.firstResponder === editor.textView || window?.firstResponder == nil { window?.makeFirstResponder(self) }
        refresh()
        updateAccessibility()
    }

    private func textSize(for item: AnnotationItem) -> CGSize {
        let inset = AnnotationRenderer.textInset(for: item)
        let maximum = max(60, bounds.width - item.rect.minX - 4) - inset.width * 2
        let size = AnnotationRenderer.measure(item.text, font: item.font, maximumWidth: maximum)
        return CGSize(width: size.width + inset.width * 2, height: size.height + inset.height * 2)
    }

    // MARK: - Keyboard

    private func cycleTool(_ direction: Int) {
        let tools = AnnotationTool.toolbarTools
        let index = tools.firstIndex(of: tool.toolbarTool) ?? 0
        let next = tools[(index + direction + tools.count) % tools.count]
        tool = next == .mosaic && style.blur ? .blur : next == .text && style.textBackground ? .note : next
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
        point = clamp(point)
        keyboardEndpoint = point
        if var item = pending, let start = item.points.first {
            if item.tool.isFreehand { item.points.append(point) }
            else { Self.update(&item, from: start, to: point, constrained: false, centered: false) }
            pending = item
        }
        refresh()
        updateAccessibility()
        return true
    }

    private func nudgeSelection(keyCode: UInt16, accelerated: Bool) -> Bool {
        guard let selectedID, var item = document.item(id: selectedID) else { return false }
        let step: CGFloat = accelerated ? 10 : 1
        switch keyCode {
        case 123: item.translate(by: CGPoint(x: -step, y: 0))
        case 124: item.translate(by: CGPoint(x: step, y: 0))
        case 125: item.translate(by: CGPoint(x: 0, y: step))
        case 126: item.translate(by: CGPoint(x: 0, y: -step))
        default: return false
        }
        commitCoalescing(item)
        return true
    }

    private func updateAccessibility() {
        let status = isFinishing ? "标注已结束" : textEditor != nil ? "正在输入文字" : keyboardEndpoint == nil ? "空格开始标注" : "正在放置，方向键移动端点，空格完成"
        setAccessibilityValue("当前工具：\(tool.title)，已有 \(document.commands.count) 条标注。\(status)。")
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func keyDown(with event: NSEvent) {
        guard !isFinishing else { return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if key == "z" { if flags.contains(.shift) { redo() } else { undo() }; return }
            if key == "s" { commitPendingEdits(); onAction?(.save); return }
            if key == "c" { commitPendingEdits(); onAction?(.copy); return }
            super.keyDown(with: event); return
        }
        if let number = Int(key), let next = AnnotationTool.forNumberKey(number) {
            tool = next == .mosaic && style.blur ? .blur : next == .text && style.textBackground ? .note : next
            return
        }
        if key == "[" || event.keyCode == 33 { cycleTool(-1); return }
        if key == "]" || event.keyCode == 30 { cycleTool(1); return }
        if moveKeyboardEndpoint(keyCode: event.keyCode, accelerated: flags.contains(.shift)) { return }
        if nudgeSelection(keyCode: event.keyCode, accelerated: flags.contains(.shift)) { return }
        switch event.keyCode {
        case 51, 117:
            if let selectedID { select(nil); document.remove(id: selectedID) }
        case 49:
            if keyboardEndpoint != nil { finishDrawing(); keyboardEndpoint = nil }
            else if tool.isTextual { beginTextEditing(at: CGPoint(x: bounds.midX, y: bounds.midY)) }
            else if tool == .step {
                document.append(AnnotationItem(tool: .step, color: style.color, width: style.width,
                    rect: CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0), number: document.nextStepNumber))
            } else {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                pending = newItem(at: center); keyboardEndpoint = center; drag = nil
                updateAccessibility()
            }
        case 36, 76: commitPendingEdits(); onAction?(.copy)
        case 53:
            if pending != nil || keyboardEndpoint != nil { clearPending() }
            else if selectedID != nil { select(nil) }
            else { onAction?(.close) }
        case 48: clearPending(); onAction?(.selection)
        default: super.keyDown(with: event)
        }
    }
}

/// Draws committed, pending and selected annotations above the base image layer.
@MainActor
private final class AnnotationOverlayView: NSView {
    weak var canvas: AnnotationCanvasView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let context = NSGraphicsContext.current?.cgContext else { return }
        let split = canvas.renderSplit
        if !split.rendered.isEmpty {
            if let image = canvas.renderedPreview {
                AnnotationRenderer.drawImage(image, in: canvas.bounds, context: context)
            } else {
                // Expensive filters are prepared by a cancellable worker, never inside AppKit drawing.
                for item in split.rendered where !item.tool.isEffect {
                    AnnotationRenderer.draw(item, in: context, effects: canvas.effects)
                }
            }
        }
        for item in split.live { AnnotationRenderer.draw(item, in: context, effects: canvas.effects) }
        guard let chrome = canvas.selectionChrome else { return }
        context.saveGState()
        let accent = NSColor.controlAccentColor.cgColor
        context.setStrokeColor(accent); context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(chrome.bounds)
        context.setLineDash(phase: 0, lengths: [])
        for point in chrome.handles {
            let handle = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.35))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: handle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(accent); context.setLineWidth(1.5); context.strokeEllipse(in: handle.insetBy(dx: 0.75, dy: 0.75))
        }
        context.restoreGState()
    }
}

/// Inline text field drawn in the annotation's own font and color, growing as the user types.
@MainActor
final class AnnotationTextEditor: NSView, NSTextViewDelegate {
    let textView = AnnotationInlineTextView()
    private(set) var item: AnnotationItem
    let isNew: Bool
    private let maximumWidth: CGFloat
    var onCommit: (() -> Void)?
    override var isFlipped: Bool { true }

    init(item: AnnotationItem, isNew: Bool, maximumWidth: CGFloat) {
        self.item = item; self.isNew = isNew; self.maximumWidth = maximumWidth
        super.init(frame: CGRect(origin: item.rect.origin, size: CGSize(width: 40, height: 30)))
        wantsLayer = true
        textView.string = item.text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.onCommit?() }
        textView.setAccessibilityLabel("标注文字")
        addSubview(textView)
        applyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func apply(style: AnnotationStyle, tool: AnnotationTool) {
        item.color = style.color
        item.font.pointSize = style.fontSize
        if tool.isTextual { item.tool = tool }
        applyAppearance(); layoutForText()
    }

    private func applyAppearance() {
        let font = AnnotationRenderer.font(item.font) as NSFont
        textView.font = font
        let note = item.tool == .note
        let color = NSColor(cgColor: item.color.cgColor) ?? .systemRed
        let noteTextColor: NSColor = item.color.luminance > 0.6 ? NSColor(white: 0.08, alpha: 1) : .white
        textView.textColor = note ? noteTextColor : color
        textView.insertionPointColor = note ? noteTextColor : color
        textView.typingAttributes = [.font: font, .foregroundColor: textView.textColor ?? color]
        layer?.cornerRadius = 6
        layer?.backgroundColor = note ? (NSColor(cgColor: item.color.cgColor) ?? .systemYellow).withAlphaComponent(0.95).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = note ? 0 : 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }

    func layoutForText() {
        var measured = item
        measured.text = textView.string
        let inset = AnnotationRenderer.textInset(for: measured)
        let size = AnnotationRenderer.measure(measured.text, font: measured.font, maximumWidth: maximumWidth - inset.width * 2)
        let width = max(size.width, measured.font.pointSize * 1.2) + 2
        textView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        textView.frame = CGRect(x: inset.width, y: inset.height, width: width, height: size.height)
        frame = CGRect(origin: item.rect.origin, size: CGSize(width: width + inset.width * 2, height: size.height + inset.height * 2))
    }

    func textDidChange(_ notification: Notification) {
        item.text = textView.string
        layoutForText()
    }
}

/// Return inserts a newline; Command-Return or Escape ends editing.
@MainActor
final class AnnotationInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        // While an input method is composing, Escape and Return belong to its candidate window.
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || ((event.keyCode == 36 || event.keyCode == 76) && flags.contains(.command)) { onCommit?(); return }
        super.keyDown(with: event)
    }
}

/// The frozen screen behind the canvas, dimmed exactly like the selector so annotating starts without a jump.
@MainActor
final class AnnotationStageView: NSView {
    override var isFlipped: Bool { true }

    init(frame: CGRect, backdrop: CGImage, selection: CGRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = backdrop
        layer?.contentsGravity = .resize
        let dim = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: frame.size))
        path.addRect(selection)
        dim.path = path
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(SelectionView.dimAlpha).cgColor
        dim.frame = CGRect(origin: .zero, size: frame.size)
        let border = CAShapeLayer()
        border.path = CGPath(rect: selection.insetBy(dx: -0.5 / max(1, scale), dy: -0.5 / max(1, scale)), transform: nil)
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1 / max(1, scale)
        border.frame = dim.frame
        layer?.addSublayer(dim)
        layer?.addSublayer(border)
    }

    required init?(coder: NSCoder) { nil }
}
