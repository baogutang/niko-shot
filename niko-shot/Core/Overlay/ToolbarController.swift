// Presents the native annotation HUD above frozen-frame overlays and releases it synchronously.
import AppKit
import QuartzCore

/// Commands that reuse the capture session's output and editing services.
enum ToolbarAction: String, CaseIterable, Sendable {
    case copy, save, pin, ocr, translate, scroll, undo, redo, selection, close

    /// VoiceOver and tooltip name for this command.
    var title: String {
        switch self {
        case .copy: "完成并复制"
        case .save: "保存"
        case .pin: "贴图"
        case .ocr: "识别文字"
        case .translate: "翻译"
        case .scroll: "长截图"
        case .undo: "撤销"
        case .redo: "重做"
        case .selection: "调整选区"
        case .close: "取消截图"
        }
    }

    /// Native SF Symbol for the command.
    var symbol: String {
        switch self {
        case .copy: "checkmark"
        case .save: "square.and.arrow.down"
        case .pin: "pin"
        case .ocr: "text.viewfinder"
        case .translate: "character.bubble"
        case .scroll: "rectangle.expand.vertical"
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
    private var scrollEnabled = true
    private var scrollExplanation = "沿当前选区捕获滚动内容。"
    private var placement: (selection: CGRect, screen: CGRect)?
    private var canUndo = false
    private var canRedo = false
    private var textResultView: NSView?
    private var preferredTextResultHeight: CGFloat = 260

    /// Number of panels retained by the controller, for session teardown assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }
    /// Whether the additional tools are visible after disclosure or selecting an advanced tool.
    var isAnnotationExpanded: Bool { content?.isAnnotationExpanded ?? false }
    /// Retained color and stroke-width popovers; finishing a session must leave none.
    var auxiliaryControlCount: Int { content?.auxiliaryControlCount ?? 0 }

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
            MainActor.assumeIsolated {
                (remainingPanel.contentView as? HUDContentView)?.closeAuxiliaryControls()
                remainingPanel.orderOut(nil); remainingPanel.contentView = nil; remainingPanel.close()
            }
        } else {
            Task { @MainActor in
                (remainingPanel.contentView as? HUDContentView)?.closeAuxiliaryControls()
                remainingPanel.orderOut(nil); remainingPanel.contentView = nil; remainingPanel.close()
            }
        }
    }

    /// Shows the HUD outside the global AppKit selection, clamped to its owning screen.
    func show(near selectionGlobal: CGRect, screenFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        let creatingPanel = panel == nil
        placement = (selectionGlobal, screenFrame)
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
            // AppKit assigns the ordinary floating level when this flag changes.
            // Set it before assigning the capture level, or the screen overlays cover the HUD.
            window.isFloatingPanel = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.acceptsMouseMovedEvents = true
            window.contentView = content
            window.onCancel = { [weak self] in
                guard let self else { return }
                self.close(); self.onAction(.close)
            }
            window.setAccessibilityLabel("截图标注工具条")
            self.content = content
            panel = window
            content.onLayoutChange = { [weak self] in self?.updateFrame() }
        }
        guard let panel, let content else { return }
        panel.acceptsTextFocus = textResultView != nil
        content.setSelectedTool(selectedTool, revealIfNeeded: creatingPanel)
        content.setTextResultView(textResultView, preferredHeight: preferredTextResultHeight, notify: false)
        content.setActionEnabled(.undo, enabled: canUndo)
        content.setActionEnabled(.redo, enabled: canRedo)
        content.setScrollAvailability(enabled: scrollEnabled, explanation: scrollExplanation)
        let frame = layoutFrame(content: content, selection: selectionGlobal, screen: available)
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
        content?.closeAuxiliaryControls()
        content?.onLayoutChange = nil
        content?.setTextResultView(nil, notify: false)
        panel = nil
        content = nil
        selectedTool = nil
        placement = nil
        textResultView = nil
        canUndo = false; canRedo = false
        oldPanel?.orderOut(nil)
        oldPanel?.onCancel = nil
        oldPanel?.contentView = nil
        oldPanel?.close()
    }

    /// Synchronizes the active tool after either pointer or keyboard selection.
    func setSelectedTool(_ tool: AnnotationTool) {
        selectedTool = tool
        content?.setSelectedTool(tool, revealIfNeeded: true)
    }

    /// Embeds OCR or translation content beneath the existing buttons, allowing native text focus while present.
    func setTextResultView(_ view: NSView?, preferredHeight: CGFloat = 260) {
        guard confirmationTitle == nil else { return }
        textResultView = view
        preferredTextResultHeight = preferredHeight.isFinite ? max(0, preferredHeight) : 260
        panel?.acceptsTextFocus = view != nil
        if view == nil, panel?.isKeyWindow == true { panel?.resignKey() }
        content?.setTextResultView(view, preferredHeight: preferredTextResultHeight)
    }

    /// Enables undo and redo only when the document has an applicable snapshot.
    func setUndoAvailability(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo; self.canRedo = canRedo
        content?.setActionEnabled(.undo, enabled: canUndo)
        content?.setActionEnabled(.redo, enabled: canRedo)
    }

    /// Keeps the visible long-capture action discoverable and explains any unavailable viewport.
    func setScrollAvailability(enabled: Bool, explanation: String) {
        scrollEnabled = enabled; scrollExplanation = explanation
        content?.setScrollAvailability(enabled: enabled, explanation: explanation)
    }

    private func updateFrame() {
        guard let panel, let content, let placement else { return }
        let frame = layoutFrame(content: content, selection: placement.selection,
                                screen: Self.safeFrame(placement.screen))
        panel.setFrame(frame, display: true)
        content.layoutSubtreeIfNeeded()
    }

    private func layoutFrame(content: HUDContentView, selection: CGRect, screen: CGRect) -> CGRect {
        let width = max(32, screen.width)
        let size = content.configure(maximumWidth: width, maximumHeight: screen.height)
        let preferred = Self.preferredFrame(near: selection, screenFrame: screen, size: size)
        guard preferred.intersects(selection) else { return preferred }
        // Wrap beside a tall selection when the toolbar or embedded result cannot fit above or below it.
        let sideWidths = [selection.minX - screen.minX - 12, screen.maxX - selection.maxX - 12]
            .filter { $0 >= 50 && $0 < width }.sorted(by: >)
        for sideWidth in sideWidths {
            let alternative = content.configure(maximumWidth: sideWidth, maximumHeight: screen.height)
            guard alternative.height <= screen.height else { continue }
            let frame = Self.preferredFrame(near: selection, screenFrame: screen, size: alternative)
            if !frame.intersects(selection) { return frame }
        }
        _ = content.configure(maximumWidth: width, maximumHeight: screen.height)
        return preferred
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
    var acceptsTextFocus = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { acceptsTextFocus }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A compact desktop toolbar with common tools, one additional row and optional inline text results.
@MainActor
final class HUDContentView: NSVisualEffectView, NSPopoverDelegate {
    private let column = NSStackView()
    private static let commonTools: [AnnotationTool] = [.rectangle, .ellipse, .arrow, .pen, .text, .mosaic]
    private var commonToolGroups: [[NSView]] = []
    private var toolGroups: [[NSView]] = []
    private var styleGroups: [[NSView]] = []
    private var commandGroups: [[NSView]] = []
    private var editingGroups: [[NSView]] = []
    private var advancedActionGroups: [[NSView]] = []
    private var annotationButton: HUDIconButton?
    private var toolButtons: [(AnnotationTool, HUDIconButton)] = []
    private var actionButtons: [ToolbarAction: HUDIconButton] = [:]
    private var colorButton: HUDIconButton?
    private var colorPopover: NSPopover?
    private var widthButton: HUDIconButton?
    private var widthPopover: NSPopover?
    private var selectedColor = 0
    private var strokeWidth: CGFloat = 3
    private var activeTool: AnnotationTool?
    private let resultContainer = NSView()
    private let resultDivider = NSBox()
    private var textResultView: NSView?
    private var preferredTextResultHeight: CGFloat = 260
    private var resultViewConstraints: [NSLayoutConstraint] = []
    private var resultWidthConstraint: NSLayoutConstraint?
    private var resultHeightConstraint: NSLayoutConstraint?
    private let onColorChange: (NSColor) -> Void
    private let onWidthChange: (CGFloat) -> Void
    private let displayNotifications = NSWorkspace.shared.notificationCenter
    private let colors: [(String, NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("白色", .white), ("黑色", .black)
    ]
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var configuredSize = CGSize.zero
    private var layoutDirty = true
    private let confirmationOnly: Bool

    /// Changes the actual owning panel frame after the inspector opens or closes.
    var onLayoutChange: (() -> Void)?
    /// The native disclosure state shared by pointer and keyboard entry points.
    private(set) var isAnnotationExpanded = false
    /// Retained transient style controllers, including those being explicitly closed.
    var auxiliaryControlCount: Int { (colorPopover == nil ? 0 : 1) + (widthPopover == nil ? 0 : 1) }

    init(onTool: @escaping (AnnotationTool) -> Void, onAction: @escaping (ToolbarAction) -> Void,
         onColor: @escaping (NSColor) -> Void, onWidth: @escaping (CGFloat) -> Void, confirmationTitle: String? = nil) {
        onColorChange = onColor
        onWidthChange = onWidth
        confirmationOnly = confirmationTitle != nil
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        resultDivider.boxType = .separator
        resultDivider.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.addSubview(resultDivider)
        let resultWidth = resultContainer.widthAnchor.constraint(equalToConstant: 0)
        let resultHeight = resultContainer.heightAnchor.constraint(equalToConstant: 0)
        resultWidthConstraint = resultWidth; resultHeightConstraint = resultHeight
        NSLayoutConstraint.activate([
            resultWidth, resultHeight,
            resultDivider.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            resultDivider.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            resultDivider.topAnchor.constraint(equalTo: resultContainer.topAnchor),
            resultDivider.heightAnchor.constraint(equalToConstant: 1)
        ])
        if confirmationTitle == nil {
            let annotation = HUDIconButton(symbol: "ellipsis", title: "更多标注工具")
            annotation.setAccessibilityExpanded(false)
            annotation.setAccessibilityHelp("展开直线、模糊、高亮、序号、便签、放大标注和调整选区。")
            annotation.onPress = { [weak self] in
                guard let self else { return }
                self.setAnnotationExpanded(!self.isAnnotationExpanded)
            }
            annotationButton = annotation
            for tool in AnnotationTool.allCases {
                let button = HUDIconButton(symbol: tool.symbol, title: tool.title)
                button.onPress = { [weak self] in self?.setSelectedTool(tool, revealIfNeeded: true); onTool(tool) }
                toolButtons.append((tool, button))
            }
            commonToolGroups = [Self.commonTools.compactMap { tool in toolButtons.first { $0.0 == tool }?.1 } + [annotation]]
            toolGroups = [toolButtons.filter { !Self.commonTools.contains($0.0) }.map { $0.1 }]
            let color = HUDIconButton(symbol: "circle.fill", title: "标注颜色：红色", tint: .systemRed)
            color.onPress = { [weak self] in self?.showColorPopover() }
            colorButton = color
            let width = HUDIconButton(symbol: "lineweight", title: "标注线宽：3 pt")
            width.onPress = { [weak self] in self?.showWidthPopover() }
            widthButton = width
            styleGroups = [[color, width]]
        }
        let groups: [[ToolbarAction]] = confirmationTitle == nil
            ? [[.undo, .redo], [.selection], [.ocr, .translate, .pin, .scroll], [.save], [.close, .copy]]
            : [[.close, .copy]]
        for group in groups {
            var views: [NSView] = []
            for action in group {
                let title = action == .copy ? (confirmationTitle ?? action.title) : action.title
                let button = HUDIconButton(symbol: action.symbol, title: title,
                                           tint: action == .copy ? HUDPalette.accent : nil,
                                           prominent: action == .copy,
                                           visibleTitle: action == .scroll ? "长截图"
                                                : action == .copy && confirmationTitle != nil ? title : nil)
                if action == .undo || action == .redo { button.isEnabled = false }
                button.toolTip = action.keyHint.map { "\(title) · \($0)" } ?? title
                button.onPress = { onAction(action) }
                actionButtons[action] = button
                views.append(button)
            }
            if group.contains(.selection) { advancedActionGroups.append(views) }
            else if group.contains(.undo) { editingGroups.append(views) }
            else { commandGroups.append(views) }
        }
        updateMoreButton()
        displayNotifications.addObserver(self, selector: #selector(displayOptionsChanged),
                                         name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    deinit { displayNotifications.removeObserver(self) }

    /// Closes transient native controls before the capture session releases its HUD.
    func closeAuxiliaryControls() {
        closeStylePopovers()
        displayNotifications.removeObserver(self)
    }

    /// Discloses all editing tools without changing the active tool or document.
    func setAnnotationExpanded(_ expanded: Bool, notify: Bool = true) {
        guard !confirmationOnly, isAnnotationExpanded != expanded else { return }
        closeStylePopovers()
        isAnnotationExpanded = expanded
        updateMoreButton()
        layoutDirty = true
        if notify { onLayoutChange?() }
    }

    private func closeStylePopovers() {
        let oldPopovers = [colorPopover, widthPopover].compactMap { $0 }
        colorPopover = nil; widthPopover = nil
        colorButton?.setSelected(false); widthButton?.setSelected(false)
        for popover in oldPopovers {
            popover.delegate = nil
            popover.animates = false
            popover.close()
            popover.contentViewController = nil
        }
    }

    /// Keeps the result view attached across button reflows so text selection and input composition survive.
    func setTextResultView(_ view: NSView?, preferredHeight: CGFloat = 260, notify: Bool = true) {
        guard !confirmationOnly || view == nil else { return }
        let height = preferredHeight.isFinite ? max(0, preferredHeight) : 260
        guard textResultView !== view || abs(preferredTextResultHeight - height) > 0.5 else { return }
        closeStylePopovers()
        if textResultView !== view {
            NSLayoutConstraint.deactivate(resultViewConstraints); resultViewConstraints.removeAll()
            textResultView?.removeFromSuperview()
            textResultView = view
            if let view {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                view.setContentHuggingPriority(.defaultLow, for: .vertical)
                resultContainer.addSubview(view)
                resultViewConstraints = [
                    view.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
                    view.topAnchor.constraint(equalTo: resultDivider.bottomAnchor, constant: 7),
                    view.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor)
                ]
                NSLayoutConstraint.activate(resultViewConstraints)
            } else {
                column.removeArrangedSubview(resultContainer); resultContainer.removeFromSuperview()
            }
        }
        preferredTextResultHeight = height
        layoutDirty = true
        if notify { onLayoutChange?() }
    }

    func configure(maximumWidth: CGFloat, maximumHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        guard layoutDirty || abs(lastWidth - maximumWidth) > 0.5 || abs(lastHeight - maximumHeight) > 0.5 else { return configuredSize }
        closeStylePopovers()
        layoutDirty = false
        lastWidth = maximumWidth
        lastHeight = maximumHeight
        for row in column.arrangedSubviews where row !== resultContainer { column.removeArrangedSubview(row); row.removeFromSuperview() }
        let limit = max(32, min(maximumWidth, 680) - 18)
        for button in actionButtons.values { button.constrainWidth(to: limit) }
        annotationButton?.constrainWidth(to: limit)
        var largest: CGFloat = 32
        var rowCount = 0
        let primaryGroups = commonToolGroups + styleGroups + editingGroups + commandGroups
        let rows = isAnnotationExpanded ? [primaryGroups, toolGroups + advancedActionGroups] : [primaryGroups]
        for groups in rows {
            var rowViews: [NSView] = []
            var rowWidth: CGFloat = 0
            func finishRow() {
                guard !rowViews.isEmpty else { return }
                let row = NSStackView(views: rowViews)
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 4
                row.setHuggingPriority(.required, for: .horizontal)
                row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
                column.insertArrangedSubview(row, at: rowCount)
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
                    let width = (view as? HUDIconButton)?.layoutWidth ?? 32
                    if pieceWidth + width > limit && !piece.isEmpty { pieces.append(piece); piece = []; pieceWidth = 0 }
                    piece.append(view)
                    pieceWidth += width
                }
                if !piece.isEmpty { pieces.append(piece) }
                for piece in pieces {
                    let width = piece.reduce(CGFloat.zero) { $0 + (($1 as? HUDIconButton)?.layoutWidth ?? 32) }
                    let separatorWidth: CGFloat = rowViews.isEmpty ? 0 : 9
                    if rowWidth + separatorWidth + width > limit && !rowViews.isEmpty { finishRow() }
                    if !rowViews.isEmpty {
                        rowViews.append(Self.separator())
                        rowWidth += 9
                    }
                    let groupView = NSStackView(views: piece)
                    groupView.orientation = .horizontal
                    groupView.alignment = .centerY
                    groupView.spacing = 0
                    groupView.widthAnchor.constraint(equalToConstant: width).isActive = true
                    rowViews.append(groupView)
                    rowWidth += width
                }
            }
            finishRow()
        }
        let buttonHeight = CGFloat(rowCount) * 32 + CGFloat(max(0, rowCount - 1)) * 2 + 14
        var resultHeight: CGFloat = 0
        if textResultView != nil {
            let availableHeight = max(0, maximumHeight - buttonHeight - 10)
            resultHeight = min(preferredTextResultHeight, availableHeight) + 10
            resultWidthConstraint?.constant = largest
            resultHeightConstraint?.constant = resultHeight - 2
            if !column.arrangedSubviews.contains(where: { $0 === resultContainer }) { column.addArrangedSubview(resultContainer) }
        }
        configuredSize = CGSize(width: min(maximumWidth, largest + 18), height: buttonHeight + resultHeight)
        return configuredSize
    }

    func setSelectedTool(_ selected: AnnotationTool?, revealIfNeeded: Bool = false) {
        activeTool = selected
        for (tool, button) in toolButtons { button.setSelected(tool.title == selected?.title) }
        actionButtons[.selection]?.setSelected(selected == nil)
        updateMoreButton()
        if revealIfNeeded, let selected, !Self.commonTools.contains(selected) { setAnnotationExpanded(true) }
    }

    private func updateMoreButton() {
        let advancedTool = activeTool.flatMap { Self.commonTools.contains($0) ? nil : $0 }
        annotationButton?.setSymbol(!isAnnotationExpanded ? advancedTool?.symbol ?? "ellipsis" : "ellipsis")
        annotationButton?.setSelected(isAnnotationExpanded || advancedTool != nil)
        annotationButton?.setAccessibilityExpanded(isAnnotationExpanded)
        annotationButton?.toolTip = isAnnotationExpanded ? "收起更多标注工具"
            : advancedTool.map { "当前工具：\($0.title) · 展开更多标注工具" } ?? "更多标注工具 · 直线、模糊、高亮、序号、便签、放大标注与调整选区"
        if let advancedTool, !isAnnotationExpanded { annotationButton?.setAccessibilityValue("当前工具：\(advancedTool.title)") }
    }

    func setActionEnabled(_ action: ToolbarAction, enabled: Bool) { actionButtons[action]?.isEnabled = enabled }

    /// Updates native help even while the long-capture action is disabled.
    func setScrollAvailability(enabled: Bool, explanation: String) {
        guard let button = actionButtons[.scroll] else { return }
        button.isEnabled = enabled
        button.toolTip = "长截图 · \(explanation)"
        button.setAccessibilityHelp(explanation)
        button.setAccessibilityValue(enabled ? "" : explanation)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = NSColor.white.withAlphaComponent(contrast ? 0.5 : 0.16).cgColor
            layer?.backgroundColor = HUDPalette.surface.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.72).cgColor
        }
    }

    @objc private func displayOptionsChanged() { updateAppearance() }

    private func showColorPopover() {
        guard let colorButton, colorButton.window != nil else { return }
        if let colorPopover, colorPopover.isShown { closeStylePopovers(); return }
        closeStylePopovers()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 184, height: 118))
        let heading = NSTextField(labelWithString: "标注颜色")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.frame = CGRect(x: 12, y: 92, width: 160, height: 17)
        content.addSubview(heading)
        for (index, value) in colors.enumerated() {
            let button = HUDIconButton(symbol: "circle.fill", title: "标注颜色：\(value.0)", tint: value.1)
            button.setSelected(index == selectedColor)
            button.onPress = { [weak self] in self?.chooseColor(index) }
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = CGRect(x: 12 + CGFloat(index % 4) * 40, y: index < 4 ? 52 : 12, width: 32, height: 32)
            content.addSubview(button)
        }
        let popover = makePopover(content: content)
        colorPopover = popover
        colorButton.setSelected(true)
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .minY)
    }

    private func chooseColor(_ index: Int) {
        guard colors.indices.contains(index) else { return }
        selectedColor = index
        let value = colors[selectedColor]
        colorButton?.setTint(value.1)
        colorButton?.toolTip = "标注颜色：\(value.0)"
        colorButton?.setAccessibilityLabel("标注颜色：\(value.0)")
        onColorChange(value.1)
        colorPopover?.close()
    }

    private func showWidthPopover() {
        guard let widthButton, widthButton.window != nil else { return }
        if let widthPopover, widthPopover.isShown { closeStylePopovers(); return }
        closeStylePopovers()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 216, height: 86))
        let heading = NSTextField(labelWithString: "线宽")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.frame = CGRect(x: 14, y: 57, width: 188, height: 17)
        let control = StrokeWidthControl(value: strokeWidth) { [weak self] value in
            guard let self else { return }
            self.strokeWidth = value
            self.widthButton?.toolTip = "标注线宽：\(Int(value)) pt"
            self.widthButton?.setAccessibilityLabel("标注线宽：\(Int(value)) pt")
            self.onWidthChange(value)
        }
        control.translatesAutoresizingMaskIntoConstraints = true
        control.frame = CGRect(x: 10, y: 9, width: 196, height: 44)
        content.addSubview(heading)
        content.addSubview(control)
        let popover = makePopover(content: content)
        widthPopover = popover
        widthButton.setSelected(true)
        popover.show(relativeTo: widthButton.bounds, of: widthButton, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover else { return }
        if closing === colorPopover {
            colorButton?.setSelected(false)
            colorPopover?.contentViewController = nil
            colorPopover?.delegate = nil
            colorPopover = nil
        } else if closing === widthPopover {
            widthButton?.setSelected(false)
            widthPopover?.contentViewController = nil
            widthPopover?.delegate = nil
            widthPopover = nil
        }
    }

    private func makePopover(content: NSView) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        return popover
    }

    private static func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([separator.widthAnchor.constraint(equalToConstant: 1), separator.heightAnchor.constraint(equalToConstant: 18)])
        return separator
    }
}

@MainActor
private enum HUDPalette {
    static let accent = NSColor(calibratedRed: 0.91, green: 0.73, blue: 0.46, alpha: 1)
    static let surface = NSColor(calibratedWhite: 0.09, alpha: 1)
}

@MainActor
private final class HUDIconButton: NSButton {
    var onPress: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var selected = false
    private var mousePressed = false
    private var symbolTint: NSColor?
    private let prominent: Bool
    private let isColorSwatch: Bool
    private let visibleTitle: String?
    private let preferredWidth: CGFloat
    private var widthConstraint: NSLayoutConstraint?
    var layoutWidth: CGFloat { widthConstraint?.constant ?? 32 }

    init(symbol: String, title: String, tint: NSColor? = nil, prominent: Bool = false, visibleTitle: String? = nil) {
        symbolTint = tint
        self.prominent = prominent
        self.visibleTitle = visibleTitle
        preferredWidth = visibleTitle.map {
            max(48, ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 30)
        } ?? 32
        isColorSwatch = symbol == "circle.fill" && tint != nil
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        self.title = visibleTitle ?? ""
        font = .systemFont(ofSize: 12, weight: .medium)
        imagePosition = visibleTitle == nil ? .imageOnly : .imageLeading
        if !isColorSwatch {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 14.5, weight: .medium))
        }
        imageScaling = .scaleNone
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(pressed)
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: preferredWidth)
        widthConstraint = width
        NSLayoutConstraint.activate([width, heightAnchor.constraint(equalToConstant: 32)])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    /// Preserves a desktop-size hit target and the visible label when narrow screens require extra rows.
    func constrainWidth(to maximumWidth: CGFloat) {
        guard visibleTitle != nil else { return }
        let width = min(preferredWidth, max(32, maximumWidth))
        widthConstraint?.constant = width
        let labelFits = width >= preferredWidth - 0.5
        imagePosition = labelFits ? .imageLeading : .imageAbove
        font = .systemFont(ofSize: labelFits ? 12 : 10, weight: .medium)
    }

    @objc private func pressed() { onPress?() }

    override var acceptsFirstResponder: Bool { isEnabled }

    // Borderless SF Symbol cells otherwise change their alignment inset when the glyph changes.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override var isEnabled: Bool { didSet { refreshAppearance() } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        refreshAppearance()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        refreshAppearance()
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        mousePressed = true
        refreshAppearance()
        super.mouseDown(with: event)
        mousePressed = false
        refreshAppearance()
    }

    func setTint(_ color: NSColor) { symbolTint = color; refreshAppearance() }

    func setSymbol(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(.init(pointSize: 14.5, weight: .medium))
    }

    override func draw(_ dirtyRect: NSRect) {
        refreshAppearance(invalidate: false)
        super.draw(dirtyRect)
        guard isColorSwatch, let symbolTint else { return }
        let circle = NSBezierPath(ovalIn: CGRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14))
        symbolTint.setFill()
        circle.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
    }

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

    private func refreshAppearance(invalidate: Bool = true) {
        contentTintColor = selected && symbolTint == nil ? HUDPalette.accent : symbolTint ?? .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if !isEnabled { background = .clear }
            else if mousePressed || cell?.isHighlighted == true { background = .labelColor.withAlphaComponent(0.14) }
            else if selected { background = HUDPalette.accent.withAlphaComponent(0.2) }
            else if prominent { background = HUDPalette.accent.withAlphaComponent(hovered ? 0.21 : 0.13) }
            else { background = hovered ? .labelColor.withAlphaComponent(0.08) : .clear }
            layer?.backgroundColor = background.cgColor
            let focused = window?.firstResponder === self
            layer?.borderWidth = focused ? 2 : selected ? 0.5 : 0
            layer?.borderColor = HUDPalette.accent.withAlphaComponent(focused ? 0.9 : 0.4).cgColor
            layer?.opacity = isEnabled ? 1 : 0.35
        }
        if invalidate { needsDisplay = true }
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
    private let slider: NSSlider
    private let label = NSTextField(labelWithString: "3 pt")
    private let onChange: (CGFloat) -> Void

    init(value: CGFloat = 3, onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(value), minValue: 1, maxValue: 16, target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: 196, height: 44))
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.numberOfTickMarks = 16
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel("标注线宽")
        slider.toolTip = "标注线宽，1–16 pt"
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.stringValue = "\(Int(value)) pt"
        let stack = NSStackView(views: [slider, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 196), heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 148), slider.heightAnchor.constraint(equalToConstant: 44),
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
