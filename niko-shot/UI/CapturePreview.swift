// Floating thumbnail after a capture: drag the file out, open the editor, pin or save; it then leaves on its own.
import AppKit
import SwiftUI

/// What the floating thumbnail shows; hover is tracked in AppKit so it also works while the panel is not key.
@MainActor @Observable
final class CapturePreviewModel {
    var image: NSImage
    var status: String
    var hovering = false
    init(image: NSImage, status: String) { self.image = image; self.status = status }
}

@MainActor
final class CapturePreviewController {
    static let shared = CapturePreviewController()
    var onEdit: ((HistoryRecord) -> Void)?
    var onPin: ((HistoryRecord) -> Void)?
    var onSave: ((HistoryRecord) -> Void)?

    private var panel: CaptureHUDPanel?
    private var record: HistoryRecord?
    private var model: CapturePreviewModel?
    private var dismissTask: Task<Void, Never>?
    private var restingFrame: CGRect = .zero
    /// Visible time before the thumbnail leaves; hovering pauses it.
    var lifetime: Duration = .seconds(5)

    var windowCount: Int { panel == nil ? 0 : 1 }
    var isShowing: Bool { panel != nil }

    /// Shows `thumbnail` for `record` in the lower-right corner of `screenFrame` (AppKit global coordinates).
    func show(record: HistoryRecord, thumbnail: CGImage, screenFrame: CGRect, status: String) {
        dismiss(animated: false)
        self.record = record
        let pointSize = Self.thumbnailSize(for: CGSize(width: thumbnail.width, height: thumbnail.height))
        let model = CapturePreviewModel(image: NSImage(cgImage: thumbnail, size: pointSize), status: status)
        self.model = model
        let margin: CGFloat = 10
        let size = CGSize(width: pointSize.width + margin * 2, height: pointSize.height + margin * 2)
        let panel = CaptureHUDPanel(level: .floating)
        panel.hasShadow = false
        let container = PreviewContainerView(frame: CGRect(origin: .zero, size: size))
        container.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        let hosting = NSHostingView(rootView: CapturePreviewView(model: model, margin: margin,
            source: URL(fileURLWithPath: record.path), date: record.createdAt,
            onClick: { [weak self] in self?.perform(\.onEdit) },
            onDragEnded: { [weak self] moved in if moved { self?.dismiss(animated: true) } },
            edit: { [weak self] in self?.perform(\.onEdit) },
            pin: { [weak self] in self?.perform(\.onPin) },
            save: { [weak self] in self?.perform(\.onSave) },
            close: { [weak self] in self?.dismiss(animated: true) }))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.setAccessibilityLabel("截图缩略图")
        let visible = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
        restingFrame = CGRect(x: visible.maxX - size.width - 12, y: visible.minY + 12, width: size.width, height: size.height)
        self.panel = panel
        if CaptureChrome.reduceMotion {
            panel.setFrame(restingFrame, display: true)
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(restingFrame.offsetBy(dx: 36, dy: 0), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(restingFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        scheduleDismiss(after: lifetime)
    }

    func dismiss(animated: Bool) {
        dismissTask?.cancel(); dismissTask = nil
        guard let old = panel else { return }
        panel = nil; record = nil; model = nil
        guard animated, !CaptureChrome.reduceMotion else { Self.close(old); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            old.animator().setFrame(old.frame.offsetBy(dx: 28, dy: 0), display: true)
            old.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { Self.close(old) } })
    }

    private static func close(_ panel: NSPanel) {
        panel.orderOut(nil); panel.contentView = nil; panel.close()
    }

    private func perform(_ action: KeyPath<CapturePreviewController, ((HistoryRecord) -> Void)?>) {
        guard let record else { return }
        let callback = self[keyPath: action]
        dismiss(animated: true)
        callback?(record)
    }

    private func hoverChanged(_ inside: Bool) {
        model?.hovering = inside
        if inside { dismissTask?.cancel(); dismissTask = nil } else { scheduleDismiss(after: .seconds(2.5)) }
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    /// Fits a capture into at most 220 × 150 points without upscaling tiny captures past 2×.
    nonisolated static func thumbnailSize(for pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 120, height: 80) }
        let scale = min(220 / pixels.width, 150 / pixels.height, 2)
        return CGSize(width: max(48, (pixels.width * scale).rounded()), height: max(36, (pixels.height * scale).rounded()))
    }

    /// Downsamples a capture off the main thread for a crisp Retina thumbnail.
    nonisolated static func makeThumbnail(_ image: CGImage, backingScale: CGFloat) -> CGImage? {
        let points = thumbnailSize(for: CGSize(width: image.width, height: image.height))
        let width = Int(points.width * backingScale), height = Int(points.height * backingScale)
        guard let context = try? ImageUtilities.context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// The system screenshot sound, so captures feel like the built-in tool; silent when turned off.
@MainActor
enum CaptureFeedback {
    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return FileManager.default.fileExists(atPath: path) ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: "Tink")
    }()

    static func playShutter() {
        guard AppSettings.shared.playsCaptureSound,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        shutter?.stop()
        shutter?.play()
    }
}

/// Reports hover for the whole panel, independent of which SwiftUI element is under the pointer.
@MainActor
private final class PreviewContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private struct CapturePreviewView: View {
    @Bindable var model: CapturePreviewModel
    let margin: CGFloat
    let source: URL
    let date: Date
    let onClick: () -> Void
    let onDragEnded: (Bool) -> Void
    let edit: () -> Void, pin: () -> Void, save: () -> Void, close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PreviewThumbnail(image: model.image, source: source, date: date, onClick: onClick, onDragEnded: onDragEnded)
            if model.hovering {
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        iconButton("xmark", "关闭", size: 22, action: close)
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        iconButton("pencil", "编辑", action: edit)
                        iconButton("pin", "贴到屏幕", action: pin)
                        iconButton("square.and.arrow.down", "另存为…", action: save)
                    }
                }
                .padding(7)
                .transition(.opacity)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Label(model.status, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    Spacer()
                }
                .padding(7)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
        .padding(margin)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("截图缩略图，\(model.status)。单击编辑，拖出得到文件")
    }

    private func iconButton(_ symbol: String, _ title: String, size: CGFloat = 28, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The thumbnail itself: a click opens the editor, a drag hands the archived file to the destination.
private struct PreviewThumbnail: NSViewRepresentable {
    let image: NSImage
    let source: URL
    let date: Date
    let onClick: () -> Void
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> PreviewThumbnailView { PreviewThumbnailView() }
    func updateNSView(_ view: PreviewThumbnailView, context: Context) {
        view.image = image; view.source = source; view.date = date; view.onClick = onClick; view.onDragEnded = onDragEnded
        view.needsDisplay = true
    }
}

@MainActor
final class PreviewThumbnailView: NSView, NSDraggingSource {
    var image: NSImage?
    var source: URL?
    var date: Date?
    var onClick: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    private var downPoint: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let source, let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downPoint = nil
        // A real file URL (named by capture time) plus PNG: promise-only drags were refused by Terminal and upload areas.
        beginDraggingSession(with: [DragExport.draggingItem(for: source, date: date, frame: bounds, image: image)], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if downPoint != nil { onClick?() }
        downPoint = nil
    }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { onDragEnded?(operation != []) }
    }
}
