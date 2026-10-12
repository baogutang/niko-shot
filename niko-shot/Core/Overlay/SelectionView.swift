// Uses Core Animation layers for frozen-frame selection; no full-screen drawRect work.
import AppKit
import QuartzCore

@MainActor
final class SelectionView: NSView {
    let frameInfo: FrozenFrame
    var onSelection: ((CGRect) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onSave: (() -> Void)?
    var candidates: [WindowCandidate] = []
    var windowMode = false
    var selectedWindow: WindowCandidate?
    var selection: CGRect = .zero { didSet { updateAccessibilitySize(); displayUpdates?.markDirty() } }
    private var anchor: CGPoint?
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let badge = CATextLayer()
    private let handlesLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeLabel = CATextLayer()
    private var tracking: NSTrackingArea?
    private var hitWindows: [WindowCandidate] = []
    private var hoverIndex = 0
    private var lastPoint = CGPoint.zero
    private var hexColor = "#000000"
    private var originalRect = CGRect.zero
    private var resizeHandle: Int?
    private var moving = false
    private var colorTask: Task<Void, Never>?
    private var displayUpdates: ActiveDisplayLink?
    private var lastDisplayStatistics = ActiveDisplayLink.Statistics()
    private var hoverRect: CGRect?
    private var loupeVisible = false
    /// Active native display links; a detached or finished selection owns none.
    var displayLinkCount: Int { displayUpdates?.isActive == true ? 1 : 0 }
    /// Real callback timing retained after explicit teardown for session measurements.
    var displayLinkStatistics: ActiveDisplayLink.Statistics { displayUpdates?.statistics ?? lastDisplayStatistics }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frameInfo: FrozenFrame) {
        self.frameInfo = frameInfo
        super.init(frame: frameInfo.screen.localBounds)
        wantsLayer = true
        layer?.contents = frameInfo.image
        layer?.contentsGravity = .resize
        dim.fillColor = NSColor.black.withAlphaComponent(0.36).cgColor
        dim.fillRule = .evenOdd
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1 / frameInfo.screen.scale
        badge.fontSize = 12
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        badge.cornerRadius = 6
        badge.contentsScale = frameInfo.screen.scale
        [dim, border, badge].forEach { layer?.addSublayer($0) }
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.controlAccentColor.cgColor
        hoverLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        hoverLayer.strokeColor = NSColor.controlAccentColor.cgColor
        hoverLayer.lineWidth = 1 / frameInfo.screen.scale
        hoverLayer.shadowColor = NSColor.controlAccentColor.cgColor
        hoverLayer.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.7
        hoverLayer.shadowRadius = 5
        loupe.bounds = CGRect(x: 0, y: 0, width: 112, height: 112)
        loupe.cornerRadius = 12; loupe.masksToBounds = true
        loupe.contents = frameInfo.image
        loupe.magnificationFilter = .nearest
        loupeLabel.fontSize = 12; loupeLabel.foregroundColor = NSColor.white.cgColor
        loupeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        loupeLabel.alignmentMode = .center; loupeLabel.contentsScale = frameInfo.screen.scale
        loupeLabel.frame = CGRect(x: 0, y: 88, width: 112, height: 24)
        loupe.addSublayer(loupeLabel)
        [hoverLayer, handlesLayer, loupe].forEach { layer?.addSublayer($0) }
        loupe.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityLabel("截图选区，拖动鼠标选择，回车复制，Escape 取消")
        updateLayers()
    }
    required init?(coder: NSCoder) { return nil }

    deinit { colorTask?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stopDisplayUpdates(); return }
        if displayUpdates == nil { displayUpdates = ActiveDisplayLink { [weak self] in self?.updateLayers() } }
        displayUpdates?.start(in: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopDisplayUpdates() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Stops native frame callbacks and pending pixel sampling before a window or stage is released.
    func stopDisplayUpdates() {
        if let displayUpdates {
            lastDisplayStatistics = displayUpdates.statistics
            displayUpdates.invalidate()
        }
        displayUpdates = nil
        colorTask?.cancel()
        colorTask = nil
    }

    private var sizeLabel: String {
        let scale = AppSettings.shared.showsPixels ? frameInfo.screen.scale : 1
        return "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) \(scale == 1 ? "pt" : "px")"
    }

    private func updateAccessibilitySize() { setAccessibilityValue(sizeLabel) }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if !selection.isEmpty { path.addRect(selection) }
        dim.path = path
        border.path = CGPath(rect: selection, transform: nil)
        let handlePath = CGMutablePath()
        if !selection.isEmpty { for point in SelectionGeometry.handles(selection) { handlePath.addEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) } }
        handlesLayer.path = handlePath
        badge.isHidden = selection.isEmpty
        badge.string = sizeLabel
        badge.frame = CGRect(x: min(max(8, selection.midX - 78), bounds.width - 164), y: max(frameInfo.screen.safeTop + 8, selection.minY - 34), width: 156, height: 26)
        hoverLayer.path = hoverRect.map { CGPath(rect: $0, transform: nil) }
        loupe.isHidden = !loupeVisible
        if loupeVisible {
            let scale = frameInfo.screen.scale
            let image = frameInfo.image
            loupe.frame.origin = CGPoint(x: min(lastPoint.x + 22, bounds.width - 120), y: max(frameInfo.screen.safeTop + 4, min(lastPoint.y + 22, bounds.height - 120)))
            loupe.contentsRect = CGRect(x: (lastPoint.x * scale - 7) / CGFloat(image.width), y: (lastPoint.y * scale - 7) / CGFloat(image.height), width: 14 / CGFloat(image.width), height: 14 / CGFloat(image.height))
            loupeLabel.string = hexColor
        }
        updateAccessibilitySize()
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if !selection.isEmpty {
            for (index, point) in SelectionGeometry.handles(selection).enumerated() {
                addCursorRect(CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12), cursor: index == 1 || index == 5 ? .resizeUpDown : .resizeLeftRight)
            }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        let point = bounded(convert(event.locationInWindow, from: nil))
        updatePointer(at: point)
    }

    private func updatePointer(at point: CGPoint) {
        lastPoint = point
        if selection.isEmpty {
            let global = CGPoint(x: frameInfo.screen.frame.minX + point.x, y: frameInfo.screen.frame.maxY - point.y)
            let hits = WindowList.hits(at: global, in: candidates)
            if hits != hitWindows { hitWindows = hits; hoverIndex = 0 }
            highlightWindow()
        }
        let image = frameInfo.image
        let scale = frameInfo.screen.scale
        loupeVisible = true
        displayUpdates?.markDirty()
        guard colorTask == nil else { return }
        colorTask = Task { [weak self] in
            let value = await Task.detached(priority: .userInitiated) { () -> String in
                guard let pixel = image.cropping(to: CGRect(x: min(CGFloat(image.width - 1), max(0, point.x * scale)), y: min(CGFloat(image.height - 1), max(0, point.y * scale)), width: 1, height: 1)), let context = try? ImageUtilities.context(width: 1, height: 1) else { return "#000000" }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return "#000000" }
                return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
            }.value
            guard !Task.isCancelled, let self else { return }
            self.colorTask = nil
            guard self.lastPoint == point else { return }
            self.hexColor = value
            self.displayUpdates?.markDirty()
        }
    }
    private func highlightWindow() {
        defer { displayUpdates?.markDirty() }
        guard !hitWindows.isEmpty else { hoverRect = nil; selectedWindow = nil; return }
        let candidate = hitWindows[hoverIndex % hitWindows.count]
        selectedWindow = candidate
        let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: candidate.frame.minX, y: candidate.frame.maxY), screen: frameInfo.screen)
        hoverRect = CGRect(origin: origin, size: candidate.frame.size).intersection(bounds)
    }
    override func mouseDown(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        let point = bounded(convert(event.locationInWindow, from: nil))
        if windowMode { selection = .zero }
        if selection.isEmpty { updatePointer(at: point) }
        window?.makeFirstResponder(self)
        anchor = point; originalRect = selection
        resizeHandle = selection.isEmpty ? nil : SelectionGeometry.handles(selection).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 9 })
        if resizeHandle == nil, !selection.isEmpty {
            if abs(point.x - selection.minX) < 5 { resizeHandle = 7 }
            else if abs(point.x - selection.maxX) < 5 { resizeHandle = 3 }
            else if abs(point.y - selection.minY) < 5 { resizeHandle = 1 }
            else if abs(point.y - selection.maxY) < 5 { resizeHandle = 5 }
        }
        moving = resizeHandle == nil && selection.contains(point)
        if !moving, resizeHandle == nil { selection = .zero }
        loupeVisible = false
        displayUpdates?.markDirty()
    }
    override func mouseDragged(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        guard !windowMode else { return }
        guard let anchor else { return }
        selectedWindow = nil; hoverRect = nil
        let point = bounded(convert(event.locationInWindow, from: nil))
        let aspect: CGFloat? = event.modifierFlags.contains(.shift) ? (originalRect.isEmpty ? 1 : originalRect.width / max(1, originalRect.height)) : nil
        if moving { selection = SelectionGeometry.clamp(originalRect.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y), bounds: bounds) }
        else if let resizeHandle {
            selection = SelectionGeometry.resize(originalRect, handle: resizeHandle, to: point, aspect: aspect, centered: event.modifierFlags.contains(.option)).intersection(bounds)
        } else { selection = SelectionGeometry.drag(anchor: anchor, point: point, aspect: aspect, centered: event.modifierFlags.contains(.option)).intersection(bounds) }
        onSelection?(selection)
    }
    override func mouseUp(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        if selection.isEmpty, let selectedWindow {
            let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: selectedWindow.frame.minX, y: selectedWindow.frame.maxY), screen: frameInfo.screen)
            selection = CGRect(origin: origin, size: selectedWindow.frame.size).intersection(bounds)
        }
        anchor = nil; moving = false; resizeHandle = nil
        onSelection?(selection)
        window?.invalidateCursorRects(for: self)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    override func keyDown(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        if event.modifierFlags.contains(.option), event.charactersIgnoringModifiers?.lowercased() == "c" {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hexColor, forType: .string); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return }
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        case 48: onAnnotate?()
        case 49: hoverIndex += 1; highlightWindow()
        case 123, 124, 125, 126:
            let delta: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) / frameInfo.screen.scale
            selection = SelectionGeometry.clamp(selection.offsetBy(dx: event.keyCode == 123 ? -delta : event.keyCode == 124 ? delta : 0, dy: event.keyCode == 126 ? -delta : event.keyCode == 125 ? delta : 0), bounds: bounds)
            onSelection?(selection)
        case 32: AppSettings.shared.showsPixels.toggle(); updateAccessibilitySize(); displayUpdates?.markDirty()
        case 35: showSizePanel()
        default: super.keyDown(with: event)
        }
    }
    private func showSizePanel() {
        let menu = NSMenu()
        for preset in AppSettings.shared.presetSizes {
            let item = NSMenuItem(title: "\(preset.name) · \(Int(preset.width)) × \(Int(preset.height))", action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = preset; menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "输入宽高…", action: #selector(customSize), keyEquivalent: "")
        custom.target = self; menu.addItem(custom)
        menu.popUp(positioning: nil, at: CGPoint(x: selection.midX, y: selection.maxY + 8), in: self)
    }
    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? CaptureSizePreset else { return }
        resize(width: preset.width, height: preset.height)
    }
    @objc private func customSize() {
        let alert = NSAlert(); alert.messageText = "选区尺寸（point）"
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let width = NSTextField(string: "\(Int(selection.width))"), height = NSTextField(string: "\(Int(selection.height))")
        let stack = NSStackView(views: [width, NSTextField(labelWithString: "×"), height]); stack.frame.size = CGSize(width: 260, height: 28)
        alert.accessoryView = stack; alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let w = Double(width.stringValue), let h = Double(height.stringValue), w > 0, h > 0 { resize(width: w, height: h) }
    }
    private func resize(width: Double, height: Double) {
        selection = SelectionGeometry.clamp(CGRect(x: selection.isEmpty ? lastPoint.x : selection.minX, y: selection.isEmpty ? lastPoint.y : selection.minY, width: width, height: height), bounds: frameInfo.screen.safeBounds)
        onSelection?(selection)
    }
    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }
}
