// The capture toolbar: one row of tools and actions, a contextual style bar, and an optional text card.
import AppKit
import QuartzCore

/// Commands that reuse the capture session's output and editing services.
enum ToolbarAction: String, CaseIterable, Sendable {
    case copy, save, pin, ocr, translate, scroll, undo, redo, selection, close

    var title: String {
        switch self {
        case .copy: "完成并复制"
        case .save: "保存"
        case .pin: "贴到屏幕"
        case .ocr: "识别文字"
        case .translate: "翻译"
        case .scroll: "长截图"
        case .undo: "撤销"
        case .redo: "重做"
        case .selection: "调整选区"
        case .close: "取消"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "checkmark"
        case .save: "square.and.arrow.down"
        case .pin: "pin"
        case .ocr: "text.viewfinder"
        case .translate: "translate"
        case .scroll: "arrow.down.to.line.compact"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .selection: "crop"
        case .close: "xmark"
        }
    }

    var keyHint: String? {
        switch self {
        case .copy: "↩"
        case .save: "⌘S"
        case .undo: "⌘Z"
        case .redo: "⇧⌘Z"
        case .selection: "⇥"
        case .close: "esc"
        default: nil
        }
    }
}

/// A nonactivating, screen-aware capture toolbar that never steals keyboard focus from the canvas.
@MainActor
final class ToolbarController {
    private var panel: CaptureHUDPanel?
    private var stack: ToolbarStackView?
    private let onTool: (AnnotationTool) -> Void
    private let onAction: (ToolbarAction) -> Void
    private let onStyle: (AnnotationStyle) -> Void
    private let confirmationTitle: String?
    private var placement: (selection: CGRect, screen: CGRect)?
    private var selectedTool: AnnotationTool?
    private var propertyTool: AnnotationTool?
    private var style = AnnotationStyle()
    private var canUndo = false, canRedo = false
    private var scrollEnabled = true
    private var scrollExplanation = "沿当前选区继续向下滚动截取。"
    private var textResultView: NSView?
    private var preferredTextResultHeight: CGFloat = 280

    var windowCount: Int { panel == nil ? 0 : 1 }
    var panelFrame: CGRect? { panel?.frame }
    var isPropertyBarVisible: Bool { stack?.properties != nil }
    /// Retained transient controls; the redesigned bars own none.
    var auxiliaryControlCount: Int { 0 }

    init(onTool: @escaping (AnnotationTool) -> Void, onAction: @escaping (ToolbarAction) -> Void,
         onStyle: @escaping (AnnotationStyle) -> Void = { _ in }, confirmationTitle: String? = nil) {
        self.onTool = onTool; self.onAction = onAction; self.onStyle = onStyle
        self.confirmationTitle = confirmationTitle
    }

    deinit {
        guard let remaining = panel else { return }
        MainActor.assumeIsolated { remaining.orderOut(nil); remaining.contentView = nil; remaining.close() }
    }

    /// Shows the toolbar next to a selection given in AppKit global coordinates.
    func show(near selectionGlobal: CGRect, screenFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        placement = (selectionGlobal, screenFrame)
        if panel == nil { makePanel() }
        guard let panel, let stack else { return }
        stack.main.setSelectedTool(selectedTool)
        stack.main.setEnabled(.undo, canUndo); stack.main.setEnabled(.redo, canRedo)
        stack.main.setScrollAvailability(enabled: scrollEnabled, explanation: scrollExplanation)
        relayout()
        CaptureChrome.present(panel, content: stack)
    }

    private func makePanel() {
        let panel = CaptureHUDPanel()
        panel.onCancel = { [weak self] in self?.onAction(.close) }
        panel.setAccessibilityLabel("截图工具栏")
        let main = ToolbarMainBar(confirmationTitle: confirmationTitle,
            onTool: { [weak self] tool in self?.chooseTool(tool) },
            onAction: { [weak self] action in self?.onAction(action) })
        let stack = ToolbarStackView(main: main)
        panel.contentView = stack
        self.panel = panel; self.stack = stack
    }

    private func chooseTool(_ tool: AnnotationTool) {
        let concrete = tool == .mosaic && style.blur ? .blur : tool == .text && style.textBackground ? .note : tool
        setSelectedTool(concrete)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onTool(concrete)
    }

    func close() {
        let old = panel
        panel = nil; stack = nil; placement = nil; selectedTool = nil; propertyTool = nil
        textResultView = nil; canUndo = false; canRedo = false
        old?.orderOut(nil); old?.onCancel = nil; old?.contentView = nil; old?.close()
    }

    /// Highlights the active tool and shows its style controls.
    func setSelectedTool(_ tool: AnnotationTool?) {
        selectedTool = tool
        stack?.main.setSelectedTool(tool)
        setPropertyContext(tool: tool)
    }

    /// Shows style controls for a tool (or the selected item's tool); nil hides the style bar.
    func setPropertyContext(tool: AnnotationTool?) {
        guard confirmationTitle == nil else { return }
        let next = tool?.toolbarTool
        guard next != propertyTool || (next != nil && stack?.properties == nil) else { return }
        propertyTool = next
        guard let stack else { return }
        if let next {
            let bar = ToolbarPropertyBar(tool: next, style: style) { [weak self] style in
                self?.style = style
                self?.onStyle(style)
            }
            stack.setProperties(bar)
        } else {
            stack.setProperties(nil)
        }
        relayout()
    }

    /// Mirrors a style adopted from a selected item.
    func setStyle(_ style: AnnotationStyle) {
        self.style = style
        stack?.properties?.update(style: style)
    }

    /// Embeds OCR or translation content under the bars; the panel accepts text focus while present.
    func setTextResultView(_ view: NSView?, preferredHeight: CGFloat = 280) {
        guard confirmationTitle == nil else { return }
        textResultView = view
        preferredTextResultHeight = preferredHeight.isFinite ? max(0, preferredHeight) : 280
        panel?.allowsKey = view != nil
        if view == nil, panel?.isKeyWindow == true { panel?.resignKey() }
        stack?.setResult(view, height: preferredTextResultHeight)
        relayout()
    }

    func setUndoAvailability(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo; self.canRedo = canRedo
        stack?.main.setEnabled(.undo, canUndo); stack?.main.setEnabled(.redo, canRedo)
    }

    func setScrollAvailability(enabled: Bool, explanation: String) {
        scrollEnabled = enabled; scrollExplanation = explanation
        stack?.main.setScrollAvailability(enabled: enabled, explanation: explanation)
    }

    /// Test access to native buttons.
    func button(for action: ToolbarAction) -> NSButton? { stack?.main.actionButtons[action] }
    func button(for tool: AnnotationTool) -> NSButton? { stack?.main.toolButtons[tool.toolbarTool] }
    var propertyButtons: [NSButton] { stack?.properties?.buttons ?? [] }

    private func relayout() {
        guard let panel, let stack, let placement else { return }
        let screen = Self.safeFrame(placement.screen)
        let size = stack.measure(maximumWidth: screen.width, maximumHeight: screen.height)
        let (frame, mainFirst) = Self.frame(for: size, near: placement.selection, screen: screen)
        stack.mainFirst = mainFirst
        panel.setFrame(frame, display: true)
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
    }

    /// Below the selection (right-aligned), else above, else inside its lower edge.
    nonisolated static func frame(for size: CGSize, near selection: CGRect, screen: CGRect) -> (CGRect, Bool) {
        let gap: CGFloat = 8
        let width = min(size.width, screen.width), height = min(size.height, screen.height)
        let x = min(max(selection.maxX - width, screen.minX), screen.maxX - width)
        let below = selection.minY - gap - height
        if below >= screen.minY { return (CGRect(x: x, y: below, width: width, height: height), true) }
        let above = selection.maxY + gap
        if above + height <= screen.maxY { return (CGRect(x: x, y: above, width: width, height: height), false) }
        let inside = min(max(screen.minY, selection.minY + gap), screen.maxY - height)
        return (CGRect(x: x, y: inside, width: width, height: height), true)
    }

    /// Compatibility wrapper used by layout tests: the toolbar's own frame next to a selection.
    nonisolated static func preferredFrame(near selection: CGRect, screenFrame: CGRect, size: CGSize) -> CGRect {
        frame(for: size, near: selection, screen: screenFrame).0
    }

    private static func safeFrame(_ screenFrame: CGRect) -> CGRect {
        var result = screenFrame.insetBy(dx: 8, dy: 8)
        if let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }), screen.safeAreaInsets.top > 0 {
            result.size.height = max(44, result.height - screen.safeAreaInsets.top)
        }
        return result
    }
}

// MARK: - Stack

/// Vertically stacked glass cards; the main bar sits nearest the selection.
@MainActor
final class ToolbarStackView: NSView {
    let main: ToolbarMainBar
    private(set) var properties: ToolbarPropertyBar?
    private var result: CaptureHUDBackground?
    private var resultHeight: CGFloat = 280
    private var preferredResultHeight: CGFloat = 280
    private var availableWidth: CGFloat = .greatestFiniteMagnitude
    var mainFirst = true { didSet { needsLayout = true } }
    private let gap: CGFloat = 6
    override var isFlipped: Bool { true }

    init(main: ToolbarMainBar) {
        self.main = main
        super.init(frame: .zero)
        addSubview(main)
    }
    required init?(coder: NSCoder) { nil }

    func setProperties(_ bar: ToolbarPropertyBar?) {
        properties?.removeFromSuperview()
        properties = bar
        if let bar {
            addSubview(bar)
            if !CaptureChrome.reduceMotion {
                bar.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.14; bar.animator().alphaValue = 1 }
            }
        }
        needsLayout = true
    }

    func setResult(_ view: NSView?, height: CGFloat) {
        result?.removeFromSuperview(); result = nil
        resultHeight = height; preferredResultHeight = height
        guard let view else { needsLayout = true; return }
        let card = CaptureHUDBackground()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        card.addSubview(view)
        addSubview(card)
        result = card
        needsLayout = true
    }

    private var cards: [(NSView, CGSize)] {
        var items: [(NSView, CGSize)] = [(main, main.measuredSize(maximumWidth: availableWidth))]
        if let properties { items.append((properties, properties.measuredSize(maximumWidth: availableWidth))) }
        if let result { items.append((result, CGSize(width: min(availableWidth, max(main.fittingWidthSize.width, 420)), height: resultHeight))) }
        return items
    }

    func measure(maximumWidth: CGFloat, maximumHeight: CGFloat) -> CGSize {
        availableWidth = maximumWidth
        resultHeight = preferredResultHeight
        let sizes = cards.map(\.1)
        let gaps = gap * CGFloat(max(0, sizes.count - 1))
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + gaps
        if naturalHeight > maximumHeight, result != nil {
            resultHeight = max(24, preferredResultHeight - (naturalHeight - maximumHeight))
        }
        let height = cards.reduce(0) { $0 + $1.1.height } + gaps
        let width = min(maximumWidth, sizes.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        var ordered = cards
        if !mainFirst { ordered.reverse() }
        var y: CGFloat = 0
        for (view, size) in ordered {
            let width = min(bounds.width, size.width)
            view.frame = CGRect(x: bounds.width - width, y: y, width: width, height: size.height)
            if view === result, let content = view.subviews.first { content.frame = view.bounds.insetBy(dx: 10, dy: 8) }
            y += size.height + gap
        }
    }
}

// MARK: - Main bar

/// Tools · undo/redo · text & long capture · pin/save · cancel/done, in one row.
@MainActor
final class ToolbarMainBar: CaptureHUDBackground {
    override var isFlipped: Bool { true }
    private(set) var toolButtons: [AnnotationTool: ToolbarButton] = [:]
    private(set) var actionButtons: [ToolbarAction: ToolbarButton] = [:]
    private var items: [NSView] = []
    private let padding: CGFloat = 5, spacing: CGFloat = 2
    static let height: CGFloat = 42

    init(confirmationTitle: String?, onTool: @escaping (AnnotationTool) -> Void, onAction: @escaping (ToolbarAction) -> Void) {
        super.init()
        func action(_ kind: ToolbarAction, prominent: Bool = false, label: String? = nil) -> ToolbarButton {
            let button = ToolbarButton(symbol: kind.symbol, title: kind.title, hint: kind.keyHint, prominent: prominent, label: label)
            button.onPress = { onAction(kind) }
            actionButtons[kind] = button
            return button
        }
        if let confirmationTitle {
            items = [action(.close), action(.copy, prominent: true, label: confirmationTitle)]
        } else {
            var row: [NSView] = []
            for tool in AnnotationTool.toolbarTools {
                let button = ToolbarButton(symbol: tool.symbol, title: tool.title, hint: tool.shortcutHint)
                button.onPress = { onTool(tool) }
                toolButtons[tool] = button
                row.append(button)
            }
            row.append(ToolbarSeparator())
            row += [action(.undo), action(.redo)]
            row.append(ToolbarSeparator())
            row += [action(.ocr), action(.translate), action(.scroll)]
            row.append(ToolbarSeparator())
            row += [action(.pin), action(.save), action(.close), action(.copy, prominent: true, label: "完成")]
            items = row
            actionButtons[.undo]?.isEnabled = false
            actionButtons[.redo]?.isEnabled = false
            actionButtons[.ocr]?.toolTip = "识别文字 · 提取截图中的文字，可编辑、复制"
            actionButtons[.translate]?.toolTip = "翻译 · 识别文字并显示译文"
        }
        items.forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    var fittingWidthSize: CGSize {
        let width = items.reduce(0) { $0 + Self.width(of: $1) } + spacing * CGFloat(max(0, items.count - 1)) + padding * 2
        return CGSize(width: width, height: Self.height)
    }

    private static func width(of view: NSView) -> CGFloat {
        (view as? ToolbarButton)?.preferredWidth ?? (view is ToolbarSeparator ? 9 : view.frame.width)
    }

    func measuredSize(maximumWidth: CGFloat) -> CGSize {
        let width = min(maximumWidth, fittingWidthSize.width)
        return ToolbarFlow.arrange(items, width: width, padding: padding, spacing: spacing, rowHeight: Self.height,
            size: { CGSize(width: Self.width(of: $0), height: $0 is ToolbarSeparator ? 20 : CaptureChrome.buttonSize) })
    }

    override func layout() {
        super.layout()
        _ = ToolbarFlow.arrange(items, width: bounds.width, padding: padding, spacing: spacing, rowHeight: Self.height,
            apply: true, size: { CGSize(width: Self.width(of: $0), height: $0 is ToolbarSeparator ? 20 : CaptureChrome.buttonSize) })
    }

    func setSelectedTool(_ tool: AnnotationTool?) {
        let shown = tool?.toolbarTool
        for (key, button) in toolButtons {
            button.isSelected = key == shown
            if key == .mosaic, let tool, tool.isEffect { button.setSymbol(tool.symbol) }
            if key == .text, let tool, tool.isTextual { button.setSymbol(tool.symbol) }
        }
    }

    func setEnabled(_ action: ToolbarAction, _ enabled: Bool) { actionButtons[action]?.isEnabled = enabled }

    func setScrollAvailability(enabled: Bool, explanation: String) {
        guard let button = actionButtons[.scroll] else { return }
        button.isEnabled = enabled
        button.toolTip = "长截图 · \(explanation)"
        button.setAccessibilityHelp(explanation)
    }
}

@MainActor
final class ToolbarSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        CaptureChrome.separator.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}

// MARK: - Property bar

/// Color, size and per-tool options for the active tool or selected annotation.
@MainActor
final class ToolbarPropertyBar: CaptureHUDBackground {
    override var isFlipped: Bool { true }
    private let tool: AnnotationTool
    private var style: AnnotationStyle
    private let onChange: (AnnotationStyle) -> Void
    private var colorButtons: [ToolbarSwatchButton] = []
    private var sizeButtons: [ToolbarButton] = []
    private var toggles: [(ToolbarButton, (inout AnnotationStyle) -> Void, (AnnotationStyle) -> Bool)] = []
    private var items: [NSView] = []
    private let padding: CGFloat = 6, spacing: CGFloat = 3
    static let height: CGFloat = 38

    var buttons: [NSButton] { colorButtons as [NSButton] + sizeButtons + toggles.map(\.0) }

    init(tool: AnnotationTool, style: AnnotationStyle, onChange: @escaping (AnnotationStyle) -> Void) {
        self.tool = tool; self.style = style; self.onChange = onChange
        super.init()
        if tool != .mosaic {
            for (index, entry) in AnnotationColor.palette.enumerated() {
                let swatch = ToolbarSwatchButton(color: entry.color, name: entry.name)
                swatch.onPress = { [weak self] in self?.change { $0.color = AnnotationColor.palette[index].color } }
                colorButtons.append(swatch); items.append(swatch)
            }
            items.append(ToolbarSeparator())
        }
        let textual = tool == .text
        let presets = textual ? AnnotationStyle.fontPresets : AnnotationStyle.widthPresets
        for (index, value) in presets.enumerated() {
            let names = textual ? ["小号文字", "中号文字", "大号文字"] : ["细", "中", "粗"]
            let button = ToolbarButton(dot: CGFloat(index), title: names[index])
            button.onPress = { [weak self] in
                self?.change { textual ? ($0.fontSize = value) : ($0.width = value) }
            }
            sizeButtons.append(button); items.append(button)
        }
        func toggle(_ symbol: String, _ title: String, apply: @escaping (inout AnnotationStyle) -> Void,
                    isOn: @escaping (AnnotationStyle) -> Bool) {
            let button = ToolbarButton(symbol: symbol, title: title, hint: nil, size: 28)
            button.onPress = { [weak self] in self?.change(apply) }
            toggles.append((button, apply, isOn))
        }
        switch tool {
        case .rectangle, .ellipse:
            toggle(tool == .rectangle ? "rectangle.fill" : "circle.fill", "填充", apply: { $0.filled.toggle() }, isOn: { $0.filled })
        case .text:
            toggle("note.text", "便签底色", apply: { $0.textBackground.toggle() }, isOn: { $0.textBackground })
        case .mosaic:
            toggle("checkerboard.rectangle", "马赛克", apply: { $0.blur = false }, isOn: { !$0.blur })
            toggle("drop.halffull", "模糊", apply: { $0.blur = true }, isOn: { $0.blur })
        default: break
        }
        if !toggles.isEmpty { items.append(ToolbarSeparator()); items += toggles.map(\.0) }
        items.forEach(addSubview)
        update(style: style)
    }

    required init?(coder: NSCoder) { nil }

    private func change(_ apply: (inout AnnotationStyle) -> Void) {
        apply(&style)
        update(style: style)
        onChange(style)
    }

    func update(style: AnnotationStyle) {
        self.style = style
        for (index, swatch) in colorButtons.enumerated() { swatch.isSelected = AnnotationColor.palette[index].color == style.color }
        let presets = tool == .text ? AnnotationStyle.fontPresets : AnnotationStyle.widthPresets
        let current = tool == .text ? style.fontSize : style.width
        let nearest = presets.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset
        for (index, button) in sizeButtons.enumerated() { button.isSelected = index == nearest }
        for (button, _, isOn) in toggles { button.isSelected = isOn(style) }
    }

    var fittingWidthSize: CGSize {
        let width = items.reduce(0) { $0 + Self.width(of: $1) } + spacing * CGFloat(max(0, items.count - 1)) + padding * 2
        return CGSize(width: width, height: Self.height)
    }

    private static func width(of view: NSView) -> CGFloat {
        if view is ToolbarSeparator { return 9 }
        if view is ToolbarSwatchButton { return 24 }
        return (view as? ToolbarButton)?.preferredWidth ?? 28
    }

    func measuredSize(maximumWidth: CGFloat) -> CGSize {
        let width = min(maximumWidth, fittingWidthSize.width)
        return ToolbarFlow.arrange(items, width: width, padding: padding, spacing: spacing, rowHeight: Self.height,
            size: { CGSize(width: Self.width(of: $0), height: $0 is ToolbarSeparator ? 18 : $0 is ToolbarSwatchButton ? 24 : 28) })
    }

    override func layout() {
        super.layout()
        _ = ToolbarFlow.arrange(items, width: bounds.width, padding: padding, spacing: spacing, rowHeight: Self.height,
            apply: true, size: { CGSize(width: Self.width(of: $0), height: $0 is ToolbarSeparator ? 18 : $0 is ToolbarSwatchButton ? 24 : 28) })
    }
}

/// Wraps native controls at their full hit size when a display cannot fit the single-row toolbar.
@MainActor
private enum ToolbarFlow {
    static func arrange(_ items: [NSView], width: CGFloat, padding: CGFloat, spacing: CGFloat, rowHeight: CGFloat,
                        apply: Bool = false, size: (NSView) -> CGSize) -> CGSize {
        var x = padding, y: CGFloat = 0
        for view in items {
            let item = size(view)
            if view is ToolbarSeparator, x == padding || x + item.width > width - padding {
                if apply { view.isHidden = true }
                continue
            }
            if x > padding, x + item.width > width - padding { x = padding; y += rowHeight }
            if apply {
                view.isHidden = false
                view.frame = CGRect(x: x, y: y + (rowHeight - item.height) / 2, width: item.width, height: item.height)
            }
            x += item.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }
}

// MARK: - Buttons

/// A layer-drawn HUD button: hover tint, pressed scale, accent fill for the selected tool.
@MainActor
class ToolbarButton: NSButton {
    var onPress: (() -> Void)?
    var isSelected = false { didSet { refresh(); setAccessibilityValue(isSelected ? "已选择" : "") } }
    let preferredWidth: CGFloat
    var drawsSelectionBackground = true
    private let prominent: Bool
    private let dotLevel: CGFloat?
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    private var symbolImage: NSImage?
    /// Scaled on press; AppKit owns the backing layer's geometry, so content lives in a sublayer.
    private let contentLayer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()
    private let dotLayer = CALayer()

    init(symbol: String, title: String, hint: String?, prominent: Bool = false, label: String? = nil, size: CGFloat = CaptureChrome.buttonSize) {
        self.prominent = prominent
        dotLevel = nil
        let labelWidth = label.map { ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width) } ?? 0
        preferredWidth = label == nil ? size : labelWidth + 40
        super.init(frame: CGRect(x: 0, y: 0, width: preferredWidth, height: size))
        configure(title: title, hint: hint)
        setSymbol(symbol)
        if let label {
            labelLayer.string = label
            labelLayer.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            labelLayer.fontSize = 12.5
            labelLayer.alignmentMode = .left
            labelLayer.foregroundColor = NSColor.white.cgColor
            labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            contentLayer.addSublayer(labelLayer)
        }
    }

    /// A size preset showing a dot whose diameter grows with the level.
    init(dot level: CGFloat, title: String) {
        prominent = false
        dotLevel = level
        preferredWidth = 28
        super.init(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        configure(title: title, hint: nil)
        dotLayer.backgroundColor = NSColor.white.cgColor
        contentLayer.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(title: String, hint: String?) {
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = CaptureChrome.buttonRadius
        layer?.cornerCurve = .continuous
        iconLayer.contentsGravity = .center
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        contentLayer.addSublayer(iconLayer)
        layer?.addSublayer(contentLayer)
        toolTip = hint.map { "\(title)  \($0)" } ?? title
        setAccessibilityLabel(title)
        target = self; action = #selector(performPress)
        focusRingType = .none
        refresh()
    }

    func setSymbol(_ symbol: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: prominent ? 12.5 : 14, weight: prominent ? .bold : .medium)
        symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        refresh()
    }

    @objc private func performPress() {
        guard isEnabled else { return }
        onPress?()
    }

    override var isEnabled: Bool { didSet { refresh() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; refresh(); scale(0.9)
        super.mouseDown(with: event)
        pressed = false; refresh(animated: true); scale(1)
    }

    private func scale(_ value: CGFloat) {
        guard !CaptureChrome.reduceMotion else { return }
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = contentLayer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = value
        animation.stiffness = 700; animation.damping = 26; animation.duration = 0.2
        contentLayer.setValue(value, forKeyPath: "transform.scale")
        contentLayer.add(animation, forKey: "press")
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentLayer.bounds = bounds
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if labelLayer.superlayer != nil {
            iconLayer.frame = CGRect(x: 10, y: 0, width: 16, height: bounds.height)
            labelLayer.frame = CGRect(x: 29, y: (bounds.height - 16) / 2 - 0.5, width: bounds.width - 31, height: 17)
        } else {
            iconLayer.frame = bounds
        }
        if let dotLevel {
            let diameter = 4 + dotLevel * 3.5
            dotLayer.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            dotLayer.cornerRadius = diameter / 2
        }
        CATransaction.commit()
    }

    func refresh(animated: Bool = false) {
        let background: NSColor
        if prominent { background = CaptureChrome.accent.withAlphaComponent(pressed ? 0.75 : hovering ? 0.88 : 1) }
        else if isSelected && drawsSelectionBackground { background = CaptureChrome.accent }
        else if pressed { background = CaptureChrome.pressed }
        else if hovering && isEnabled { background = CaptureChrome.hover }
        else { background = .clear }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || CaptureChrome.reduceMotion)
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = background.cgColor
        layer?.opacity = isEnabled ? 1 : 0.35
        CATransaction.commit()
        let tint: NSColor = prominent || (isSelected && drawsSelectionBackground) ? .white : CaptureChrome.primaryText
        CATransaction.begin(); CATransaction.setDisableActions(true)
        iconLayer.contents = symbolImage?.tinted(tint)
        dotLayer.backgroundColor = (isSelected ? NSColor.white : CaptureChrome.primaryText).cgColor
        CATransaction.commit()
        needsDisplay = true
    }
}

/// A round color well with a ring around the current color.
@MainActor
final class ToolbarSwatchButton: ToolbarButton {
    private let color: AnnotationColor
    override var isSelected: Bool { didSet { needsDisplay = true } }

    init(color: AnnotationColor, name: String) {
        self.color = color
        super.init(symbol: "", title: name, hint: nil, size: 24)
        drawsSelectionBackground = false
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 2, dy: 2)
        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: outer.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
        }
        let inner = outer.insetBy(dx: isSelected ? 4 : 2.5, dy: isSelected ? 4 : 2.5)
        (NSColor(cgColor: color.cgColor) ?? .systemRed).setFill()
        NSBezierPath(ovalIn: inner).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(ovalIn: inner.insetBy(dx: 0.25, dy: 0.25)); edge.lineWidth = 0.5; edge.stroke()
    }
}

private extension NSImage {
    /// Returns a template-tinted copy so SF Symbols render in the HUD's colors inside a CALayer.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
