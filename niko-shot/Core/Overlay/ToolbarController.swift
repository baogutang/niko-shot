// Presents the native annotation HUD above frozen-frame overlays and releases it synchronously.
import AppKit
import QuartzCore

/// Commands that reuse the capture session's output and editing services.
enum ToolbarAction: String, CaseIterable, Sendable {
    case copy, save, pin, ocr, scroll, undo, redo, selection, close

    /// VoiceOver and tooltip name for this command.
    var title: String {
        switch self {
        case .copy: "复制"
        case .save: "保存"
        case .pin: "贴图"
        case .ocr: "识别文字"
        case .scroll: "滚动长截图"
        case .undo: "撤销"
        case .redo: "重做"
        case .selection: "调整选区"
        case .close: "取消截图"
        }
    }

    /// Native SF Symbol for the command.
    var symbol: String {
        switch self {
        case .copy: "doc.on.clipboard"
        case .save: "square.and.arrow.down"
        case .pin: "pin"
        case .ocr: "text.viewfinder"
        case .scroll: "scroll"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .selection: "crop"
        case .close: "xmark"
        }
    }

    fileprivate var keyHint: String? {
        switch self {
        case .copy: "Enter"
        case .save: "⌘S"
        case .undo: "⌘Z"
        case .redo: "⇧⌘Z"
        case .selection: "Tab"
        case .close: "Esc"
        default: nil
        }
    }
}

/// A nonactivating, screen-aware AppKit annotation toolbar.
@MainActor
final class ToolbarController {
    // App coordinators own this object on the main actor. Unsafe storage only supports
    // normal deinit on macOS 14/15, whose runtimes cannot safely run isolated deinit.
    nonisolated(unsafe) private var panel: HUDPanel?
    private var content: HUDContentView?
    private var selectedTool: AnnotationTool?
    private let onTool: (AnnotationTool) -> Void
    private let onAction: (ToolbarAction) -> Void
    private let onColor: (NSColor) -> Void
    private let onWidth: (CGFloat) -> Void
    private let confirmationTitle: String?

    /// Number of panels retained by the controller, for session teardown assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }

    /// Creates the HUD without opening a panel or registering event monitors.
    init(onTool: @escaping (AnnotationTool) -> Void,
         onAction: @escaping (ToolbarAction) -> Void,
         onColor: @escaping (NSColor) -> Void,
         onWidth: @escaping (CGFloat) -> Void, confirmationTitle: String? = nil) {
        self.confirmationTitle = confirmationTitle
        self.onTool = onTool
        self.onAction = onAction
        self.onColor = onColor
        self.onWidth = onWidth
    }

    deinit {
        guard let remainingPanel = panel else { return }
        // Normal use calls close() first; this fallback also handles release off the main thread.
        if Thread.isMainThread {
            MainActor.assumeIsolated { remainingPanel.orderOut(nil); remainingPanel.close() }
        } else {
            Task { @MainActor in remainingPanel.orderOut(nil); remainingPanel.close() }
        }
    }

    /// Shows the HUD outside the global AppKit selection, clamped to its owning screen.
    func show(near selectionGlobal: CGRect, screenFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        let available = Self.safeFrame(screenFrame)
        if panel == nil {
            let content = HUDContentView(onTool: { [weak self] tool in
                guard let self else { return }
                self.setSelectedTool(tool)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                self.onTool(tool)
            }, onAction: { [weak self] action in
                guard let self else { return }
                if action == .selection {
                    self.selectedTool = nil
                    self.content?.setSelectedTool(nil)
                }
                if action == .close { self.close() }
                self.onAction(action)
            }, onColor: { [weak self] in self?.onColor($0) }, onWidth: { [weak self] in self?.onWidth($0) }, confirmationTitle: confirmationTitle)
            let window = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.isFloatingPanel = true
            window.acceptsMouseMovedEvents = true
            window.contentView = content
            window.setAccessibilityLabel("截图标注工具条")
            self.content = content
            panel = window
        }
        guard let panel, let content else { return }
        let size = content.configure(maximumWidth: max(44, available.width))
        content.setSelectedTool(selectedTool)
        let frame = Self.preferredFrame(near: selectionGlobal, screenFrame: available, size: size)
        let isNewlyShown = !panel.isVisible
        panel.setFrame(frame, display: true)
        if isNewlyShown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.97
            spring.toValue = 1
            spring.stiffness = 400
            spring.damping = 30
            spring.mass = 1
            spring.duration = 0.15
            content.layer?.add(spring, forKey: "HUDEntrance")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// Immediately removes the panel, tracking areas and controls from the capture session.
    func close() {
        let oldPanel = panel
        panel = nil
        content = nil
        selectedTool = nil
        oldPanel?.orderOut(nil)
        oldPanel?.contentView = nil
        oldPanel?.close()
    }

    /// Synchronizes the active tool after either pointer or keyboard selection.
    func setSelectedTool(_ tool: AnnotationTool) {
        selectedTool = tool
        content?.setSelectedTool(tool)
    }

    /// Enables undo and redo only when the document has an applicable snapshot.
    func setUndoAvailability(canUndo: Bool, canRedo: Bool) {
        content?.setActionEnabled(.undo, enabled: canUndo)
        content?.setActionEnabled(.redo, enabled: canRedo)
    }

    /// Computes a deterministic placement, preferring below, above, then either side.
    nonisolated static func preferredFrame(near selection: CGRect, screenFrame: CGRect, size requestedSize: CGSize) -> CGRect {
        let size = CGSize(width: min(requestedSize.width, screenFrame.width), height: min(requestedSize.height, screenFrame.height))
        let gap: CGFloat = 12
        func clamp(_ frame: CGRect) -> CGRect {
            CGRect(x: min(max(frame.minX, screenFrame.minX), screenFrame.maxX - size.width),
                   y: min(max(frame.minY, screenFrame.minY), screenFrame.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let candidates = [
            CGRect(x: selection.midX - size.width / 2, y: selection.minY - size.height - gap, width: size.width, height: size.height),
            CGRect(x: selection.midX - size.width / 2, y: selection.maxY + gap, width: size.width, height: size.height),
            CGRect(x: selection.maxX + gap, y: selection.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: selection.minX - size.width - gap, y: selection.midY - size.height / 2, width: size.width, height: size.height)
        ]
        let placements = candidates.map(clamp)
        if let outside = placements.first(where: { !$0.intersects(selection) }) { return outside }
        return placements.min { lhs, rhs in
            let left = lhs.intersection(selection)
            let right = rhs.intersection(selection)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        } ?? clamp(candidates[0])
    }

    private static func safeFrame(_ screenFrame: CGRect) -> CGRect {
        var result = screenFrame.insetBy(dx: 8, dy: 8)
        if let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }), screen.safeAreaInsets.top > 0 {
            result.size.height = max(44, result.height - screen.safeAreaInsets.top)
        }
        return result
    }
}

@MainActor
private final class HUDPanel: NSPanel {
    // Keeping the overlay key preserves Enter, Esc and tool shortcuts during pointer use.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class HUDContentView: NSVisualEffectView {
    private let column = NSStackView()
    private var toolGroups: [[NSView]] = []
    private var commandGroups: [[NSView]] = []
    private var toolButtons: [(AnnotationTool, HUDIconButton)] = []
    private var actionButtons: [ToolbarAction: HUDIconButton] = [:]
    private var colorButtons: [HUDIconButton] = []
    private var lastWidth: CGFloat = 0
    private var configuredSize = CGSize.zero

    init(onTool: @escaping (AnnotationTool) -> Void, onAction: @escaping (ToolbarAction) -> Void,
         onColor: @escaping (NSColor) -> Void, onWidth: @escaping (CGFloat) -> Void, confirmationTitle: String? = nil) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        if confirmationTitle == nil {
        let tools = Array(AnnotationTool.allCases)
        for start in stride(from: 0, to: tools.count, by: 4) {
            var group: [NSView] = []
            for tool in tools[start..<min(start + 4, tools.count)] {
                let button = HUDIconButton(symbol: tool.symbol, title: tool.title)
                button.onPress = { onTool(tool) }
                toolButtons.append((tool, button))
                group.append(button)
            }
            toolGroups.append(group)
        }
        let colors: [(String, NSColor)] = [
            ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
            ("绿色", .systemGreen), ("蓝色", .systemBlue), ("白色", .white), ("黑色", .black)
        ]
        for (index, value) in colors.enumerated() {
            let button = HUDIconButton(symbol: "circle.fill", title: "标注颜色：\(value.0)", tint: value.1)
            button.setSelected(index == 0)
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                for other in self.colorButtons { other.setSelected(other === button) }
                onColor(value.1)
            }
            colorButtons.append(button)
        }
        commandGroups.append(colorButtons)
        commandGroups.append([StrokeWidthControl(onChange: onWidth)])
        }
        let groups: [[ToolbarAction]] = confirmationTitle == nil ? [[.undo, .redo], [.selection], [.copy, .save, .pin, .ocr, .scroll], [.close]] : [[.copy], [.close]]
        for group in groups {
            var views: [NSView] = []
            for action in group {
                let title = action == .copy ? (confirmationTitle ?? action.title) : action.title
                let button = HUDIconButton(symbol: action == .copy && confirmationTitle != nil ? "checkmark.circle" : action.symbol, title: title)
                button.toolTip = action.keyHint.map { "\(title) · \($0)" } ?? title
                button.onPress = { onAction(action) }
                actionButtons[action] = button
                views.append(button)
            }
            commandGroups.append(views)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func configure(maximumWidth: CGFloat) -> CGSize {
        guard abs(lastWidth - maximumWidth) > 0.5 else { return configuredSize }
        lastWidth = maximumWidth
        for row in column.arrangedSubviews { column.removeArrangedSubview(row); row.removeFromSuperview() }
        let limit = max(44, maximumWidth - 24)
        var largest: CGFloat = 44
        var rowCount = 0
        for groups in [toolGroups, commandGroups] {
            var rowViews: [NSView] = []
            var rowWidth: CGFloat = 0
            func finishRow() {
                guard !rowViews.isEmpty else { return }
                let row = NSStackView(views: rowViews)
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                row.setHuggingPriority(.required, for: .horizontal)
                column.addArrangedSubview(row)
                largest = max(largest, rowWidth)
                rowCount += 1
                rowViews = []
                rowWidth = 0
            }
            for group in groups {
                var pieces: [[NSView]] = []
                var piece: [NSView] = []
                var pieceWidth: CGFloat = 0
                for view in group {
                    let width = view is StrokeWidthControl ? CGFloat(124) : 44
                    if pieceWidth + width > limit && !piece.isEmpty { pieces.append(piece); piece = []; pieceWidth = 0 }
                    piece.append(view)
                    pieceWidth += width
                }
                if !piece.isEmpty { pieces.append(piece) }
                for piece in pieces {
                    let width = piece.reduce(CGFloat.zero) { $0 + ($1 is StrokeWidthControl ? 124 : 44) }
                    let separatorWidth: CGFloat = rowViews.isEmpty ? 0 : 13
                    if rowWidth + separatorWidth + width > limit && !rowViews.isEmpty { finishRow() }
                    if !rowViews.isEmpty {
                        rowViews.append(Self.separator())
                        rowWidth += 13
                    }
                    let groupView = NSStackView(views: piece)
                    groupView.orientation = .horizontal
                    groupView.alignment = .centerY
                    groupView.spacing = 0
                    rowViews.append(groupView)
                    rowWidth += width
                }
            }
            finishRow()
        }
        configuredSize = CGSize(width: min(maximumWidth, largest + 24), height: CGFloat(rowCount) * 44 + CGFloat(max(0, rowCount - 1)) * 4 + 16)
        return configuredSize
    }

    func setSelectedTool(_ selected: AnnotationTool?) {
        for (tool, button) in toolButtons { button.setSelected(tool.title == selected?.title) }
        actionButtons[.selection]?.setSelected(selected == nil)
    }

    func setActionEnabled(_ action: ToolbarAction, enabled: Bool) { actionButtons[action]?.isEnabled = enabled }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor }
    }

    private static func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([separator.widthAnchor.constraint(equalToConstant: 1), separator.heightAnchor.constraint(equalToConstant: 24)])
        return separator
    }
}

@MainActor
private final class HUDIconButton: NSButton {
    var onPress: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var selected = false
    private let symbolTint: NSColor?

    init(symbol: String, title: String, tint: NSColor? = nil) {
        symbolTint = tint
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        imageScaling = .scaleNone
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(pressed)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44)])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func pressed() { onPress?() }

    func setSelected(_ value: Bool) {
        selected = value
        setAccessibilityValue(value ? "已选择" : "")
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refreshAppearance(); animateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshAppearance(); animateHover() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }

    private func refreshAppearance() {
        contentTintColor = symbolTint ?? .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.24) : hovered ? NSColor.labelColor.withAlphaComponent(0.09) : NSColor.clear).cgColor
        }
    }

    private func animateHover() {
        guard let layer else { return }
        let scale: CGFloat = hovered && isEnabled ? 1.06 : 1
        let previous = layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: "HUDHover")
            layer.setAffineTransform(.identity)
            return
        }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = previous
        spring.toValue = scale
        spring.stiffness = 400
        spring.damping = 30
        spring.duration = 0.15
        layer.add(spring, forKey: "HUDHover")
    }
}

@MainActor
private final class StrokeWidthControl: NSView {
    private let slider = NSSlider(value: 3, minValue: 1, maxValue: 16, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "3 pt")
    private let onChange: (CGFloat) -> Void

    init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: 124, height: 44))
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.setAccessibilityLabel("标注线宽")
        slider.toolTip = "标注线宽，1–16 pt"
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [slider, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 124), heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 78), slider.heightAnchor.constraint(equalToConstant: 44),
            label.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() {
        let width = CGFloat(slider.doubleValue.rounded())
        label.stringValue = "\(Int(width)) pt"
        onChange(width)
    }
}
