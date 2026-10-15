// Uses Core Animation layers for frozen-frame selection; no full-screen drawRect work.
import AppKit
import QuartzCore

@MainActor
final class SelectionView: NSView {
    /// Darkening outside the selection; the annotation stage reuses it so the screen never changes tone.
    static let dimAlpha: CGFloat = 0.36
    let frameInfo: FrozenFrame
    var onSelection: ((CGRect) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onSave: (() -> Void)?
    /// Only a completed mouse gesture starts direct scrolling; intermediate drags never do.
    var onSelectionCompleted: (() -> Void)?
    var onSelectionModeChanged: (() -> Void)?
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
    /// Magnifier: a pixel-exact zoom with a grid and the centre pixel outlined, then coordinates and colour.
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    private let loupeLabel = CATextLayer()
    private static let loupePixels = 15
    private static let loupeSide: CGFloat = 135
    private static let loupeInfoHeight: CGFloat = 36
    private var dragging = false
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
    private var scrollModeControl: NSSegmentedControl?
    private var scrollHint: NSTextField?
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
        dim.fillColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
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
        let side = Self.loupeSide, cell = side / CGFloat(Self.loupePixels)
        loupe.bounds = CGRect(x: 0, y: 0, width: side, height: side + Self.loupeInfoHeight)
        loupe.anchorPoint = .zero
        loupe.cornerRadius = 12; loupe.cornerCurve = .continuous; loupe.masksToBounds = true
        loupe.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        loupe.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        loupe.borderWidth = 1 / frameInfo.screen.scale
        loupeImage.frame = CGRect(x: 0, y: 0, width: side, height: side)
        loupeImage.contents = frameInfo.image
        loupeImage.magnificationFilter = .nearest
        let grid = CGMutablePath()
        for index in 1..<Self.loupePixels {
            let offset = CGFloat(index) * cell
            grid.move(to: CGPoint(x: offset, y: 0)); grid.addLine(to: CGPoint(x: offset, y: side))
            grid.move(to: CGPoint(x: 0, y: offset)); grid.addLine(to: CGPoint(x: side, y: offset))
        }
        loupeGrid.frame = loupeImage.frame
        loupeGrid.path = grid
        loupeGrid.strokeColor = NSColor.black.withAlphaComponent(0.16).cgColor
        loupeGrid.lineWidth = 1 / frameInfo.screen.scale
        let middle = CGFloat(Self.loupePixels / 2) * cell
        loupeCenter.frame = loupeImage.frame
        loupeCenter.path = CGPath(rect: CGRect(x: middle, y: middle, width: cell, height: cell), transform: nil)
        loupeCenter.fillColor = NSColor.clear.cgColor
        loupeCenter.strokeColor = NSColor.white.cgColor
        loupeCenter.lineWidth = 1.5
        loupeCenter.shadowColor = NSColor.black.cgColor; loupeCenter.shadowOpacity = 0.8
        loupeCenter.shadowRadius = 1; loupeCenter.shadowOffset = .zero
        loupeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        loupeLabel.fontSize = 11; loupeLabel.foregroundColor = NSColor.white.cgColor
        loupeLabel.alignmentMode = .center; loupeLabel.contentsScale = frameInfo.screen.scale
        loupeLabel.frame = CGRect(x: 4, y: side + 3, width: side - 8, height: Self.loupeInfoHeight - 6)
        [loupeImage, loupeGrid, loupeCenter, loupeLabel].forEach { loupe.addSublayer($0) }
        [hoverLayer, handlesLayer, loupe].forEach { layer?.addSublayer($0) }
        loupe.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityLabel("截图选区，拖动鼠标选择，回车复制，Escape 取消")
        updateLayers()
    }
    required init?(coder: NSCoder) { return nil }

    /// Exposes window and region capture directly on the native selector, without another setup window.
    func configureForScrollSelection() {
        windowMode = true
        let width = min(360, max(200, bounds.width - 32))
        let surface = NSVisualEffectView(frame: CGRect(x: (bounds.width - width) / 2,
            y: frameInfo.screen.safeTop + 12, width: width, height: 74))
        surface.material = .hudWindow; surface.blendingMode = .withinWindow; surface.state = .active
        surface.wantsLayer = true; surface.layer?.cornerRadius = 12; surface.layer?.masksToBounds = true
        let modes = NSSegmentedControl(labels: ["选择窗口", "框选区域"], trackingMode: .selectOne,
                                      target: self, action: #selector(changeScrollMode(_:)))
        modes.frame = CGRect(x: 12, y: 38, width: width - 24, height: 26)
        modes.selectedSegment = 0
        modes.setAccessibilityLabel("长截图捕获范围，默认选择窗口")
        modes.setAccessibilityHelp("单击窗口直接开始；可切换到区域后拖动选择。Tab 切换范围，Escape 取消。")
        let hint = NSTextField(labelWithString: "单击窗口开始 · 空格切换重叠窗口 · Esc 取消")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.alignment = .center; hint.frame = CGRect(x: 8, y: 10, width: width - 16, height: 20)
        surface.addSubview(modes); surface.addSubview(hint); addSubview(surface)
        scrollModeControl = modes; scrollHint = hint
        setAccessibilityLabel("长截图选区：单击窗口直接开始，Tab 切换为框选区域，Escape 取消")
    }

    @objc private func changeScrollMode(_ sender: NSSegmentedControl) {
        windowMode = sender.selectedSegment == 0
        selection = .zero; selectedWindow = nil; hoverRect = nil; anchor = nil
        scrollHint?.stringValue = windowMode ? "单击窗口开始 · 空格切换重叠窗口 · Esc 取消" : "拖动框选后直接开始 · Tab 切换窗口 · Esc 取消"
        onSelectionModeChanged?()
        window?.makeFirstResponder(self)
        displayUpdates?.markDirty()
    }

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
        if scrollModeControl != nil, !selection.isEmpty, selection.height * frameInfo.screen.scale < 240 {
            badge.string = "选区至少需要 240 px 高"
        }
        badge.frame = CGRect(x: min(max(8, selection.midX - 78), bounds.width - 164), y: max(frameInfo.screen.safeTop + 8, selection.minY - 34), width: 156, height: 26)
        hoverLayer.path = hoverRect.map { CGPath(rect: $0, transform: nil) }
        loupe.isHidden = !loupeVisible
        if loupeVisible {
            let scale = frameInfo.screen.scale
            let image = frameInfo.image
            loupe.position = Self.loupeOrigin(for: lastPoint, size: loupe.bounds.size, in: bounds, safeTop: frameInfo.screen.safeTop)
            let pixels = CGFloat(Self.loupePixels), half = CGFloat(Self.loupePixels / 2)
            let pixelX = min(CGFloat(image.width - 1), max(0, (lastPoint.x * scale).rounded(.down)))
            let pixelY = min(CGFloat(image.height - 1), max(0, (lastPoint.y * scale).rounded(.down)))
            loupeImage.contentsRect = CGRect(x: (pixelX - half) / CGFloat(image.width), y: (pixelY - half) / CGFloat(image.height),
                                             width: pixels / CGFloat(image.width), height: pixels / CGFloat(image.height))
            loupeLabel.string = "\(Int(pixelX)), \(Int(pixelY))\n\(hexColor)"
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
                addCursorRect(CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12), cursor: SelectionCursors.cursor(forHandle: index))
            }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        let point = bounded(convert(event.locationInWindow, from: nil))
        updatePointer(at: point)
    }

    /// Beside the pointer (down and right), flipped to the other side near a screen edge so it never covers the target.
    static func loupeOrigin(for point: CGPoint, size: CGSize, in bounds: CGRect, safeTop: CGFloat) -> CGPoint {
        let gap: CGFloat = 20, margin: CGFloat = 6
        var x = point.x + gap, y = point.y + gap
        if x + size.width > bounds.maxX - margin { x = point.x - gap - size.width }
        if y + size.height > bounds.maxY - margin { y = point.y - gap - size.height }
        x = min(max(bounds.minX + margin, x), bounds.maxX - size.width - margin)
        y = min(max(safeTop + margin, y), bounds.maxY - size.height - margin)
        return CGPoint(x: x, y: y)
    }

    /// The magnifier helps while choosing or adjusting an edge, not while the pointer rests inside a finished selection.
    private func wantsLoupe(at point: CGPoint) -> Bool {
        guard scrollModeControl == nil else { return false }
        if dragging || selection.isEmpty { return true }
        return !selection.insetBy(dx: 14, dy: 14).contains(point) && selection.insetBy(dx: -14, dy: -14).contains(point)
    }

    private func updatePointer(at point: CGPoint) {
        lastPoint = point
        if selection.isEmpty, !dragging {
            let global = CGPoint(x: frameInfo.screen.frame.minX + point.x, y: frameInfo.screen.frame.maxY - point.y)
            let hits = WindowList.hits(at: global, in: candidates)
            if hits != hitWindows { hitWindows = hits; hoverIndex = 0 }
            highlightWindow()
        }
        guard wantsLoupe(at: point) else {
            loupeVisible = false; displayUpdates?.markDirty()
            return
        }
        loupeVisible = true
        displayUpdates?.markDirty()
        sampleColor()
    }

    /// Reads the pixel under the pointer as sRGB hex; when the pointer has moved on, the latest point is read next.
    private func sampleColor() {
        guard colorTask == nil else { return }
        let image = frameInfo.image, scale = frameInfo.screen.scale, point = lastPoint
        colorTask = Task { [weak self] in
            let value = await Task.detached(priority: .userInitiated) {
                Self.hex(of: image, atPixel: CGPoint(x: point.x * scale, y: point.y * scale))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.colorTask = nil
            self.hexColor = value
            self.displayUpdates?.markDirty()
            if self.lastPoint != point, self.loupeVisible { self.sampleColor() }
        }
    }

    /// The sRGB colour of one image pixel (top-left origin), as designers and web code expect it.
    nonisolated static func hex(of image: CGImage, atPixel pixel: CGPoint) -> String {
        let x = min(CGFloat(image.width - 1), max(0, pixel.x.rounded(.down)))
        let y = min(CGFloat(image.height - 1), max(0, pixel.y.rounded(.down)))
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "#000000" }
        var bytes: [UInt8] = [0, 0, 0, 0]
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2]) : "#000000"
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
        // Moving the whole selection needs no pixel aim; drawing and edge resizing do.
        loupeVisible = !moving && scrollModeControl == nil && !windowMode
        displayUpdates?.markDirty()
    }
    override func mouseDragged(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        guard !windowMode else { return }
        guard let anchor else { return }
        selectedWindow = nil; hoverRect = nil
        let point = bounded(convert(event.locationInWindow, from: nil))
        dragging = !moving
        let aspect: CGFloat? = event.modifierFlags.contains(.shift) ? (originalRect.isEmpty ? 1 : originalRect.width / max(1, originalRect.height)) : nil
        if moving { selection = SelectionGeometry.clamp(originalRect.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y), bounds: bounds) }
        else if let resizeHandle {
            selection = SelectionGeometry.resize(originalRect, handle: resizeHandle, to: point, aspect: aspect, centered: event.modifierFlags.contains(.option)).intersection(bounds)
        } else { selection = SelectionGeometry.drag(anchor: anchor, point: point, aspect: aspect, centered: event.modifierFlags.contains(.option)).intersection(bounds) }
        if dragging { updatePointer(at: point) } else { loupeVisible = false }
        onSelection?(selection)
    }
    override func mouseUp(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        if selection.isEmpty, let selectedWindow {
            let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: selectedWindow.frame.minX, y: selectedWindow.frame.maxY), screen: frameInfo.screen)
            selection = CGRect(origin: origin, size: selectedWindow.frame.size).intersection(bounds)
        }
        anchor = nil; moving = false; resizeHandle = nil; dragging = false
        updatePointer(at: bounded(convert(event.locationInWindow, from: nil)))
        onSelection?(selection)
        window?.invalidateCursorRects(for: self)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if !selection.isEmpty { onSelectionCompleted?() }
    }
    override func keyDown(with event: NSEvent) {
        displayUpdates?.recordInputEvent()
        if event.modifierFlags.contains(.option), event.charactersIgnoringModifiers?.lowercased() == "c" {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hexColor, forType: .string); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return }
        switch event.keyCode {
        case 36, 76:
            if scrollModeControl != nil, selection.isEmpty, windowMode, let selectedWindow {
                let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: selectedWindow.frame.minX, y: selectedWindow.frame.maxY), screen: frameInfo.screen)
                selection = CGRect(origin: origin, size: selectedWindow.frame.size).intersection(bounds)
                onSelection?(selection)
            }
            onConfirm?()
        case 53: onCancel?()
        case 48:
            if let modes = scrollModeControl { modes.selectedSegment = windowMode ? 1 : 0; changeScrollMode(modes) }
            else { onAnnotate?() }
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
