// Shows the recording core's camera session through a native GPU-backed preview layer.
import AppKit
import AVFoundation

/// Owns the movable camera preview independently of capture and video composition.
@MainActor
final class CameraPiPController: NSObject {
    nonisolated(unsafe) private var panel: CameraPreviewPanel?
    private var preview: CameraPreviewView?
    private let onClose: (() -> Void)?

    /// Number of retained camera preview windows.
    var windowCount: Int { panel == nil ? 0 : 1 }

    /// Optional user-close callback lets the coordinator disable camera composition too.
    init(onClose: (() -> Void)? = nil) { self.onClose = onClose; super.init() }

    deinit {
        guard let remaining = panel else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                (remaining.contentView as? CameraPreviewView)?.previewLayer.session = nil
                remaining.orderOut(nil); remaining.contentView = nil; remaining.close()
            }
        } else {
            Task { @MainActor in
                (remaining.contentView as? CameraPreviewView)?.previewLayer.session = nil
                remaining.orderOut(nil); remaining.contentView = nil; remaining.close()
            }
        }
    }

    /// Shows an already configured camera session; this view never starts a second camera capture.
    func show(session: AVCaptureSession) {
        if let panel, let preview {
            preview.previewLayer.session = session
            panel.orderFrontRegardless()
            return
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: 240, height: 135)
        let window = CameraPreviewPanel(contentRect: CGRect(x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width, height: size.height),
                                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.contentAspectRatio = CGSize(width: 16, height: 9)
        window.minSize = CGSize(width: 120, height: 67.5)
        window.maxSize = CGSize(width: 320, height: 180)
        window.setAccessibilityLabel("摄像头画中画预览，拖动移动，双指缩放")
        let preview = CameraPreviewView(frame: CGRect(origin: .zero, size: size))
        preview.previewLayer.session = session
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭摄像头画中画") ?? NSImage(), target: self, action: #selector(userClose))
        close.isBordered = false
        close.imageScaling = .scaleNone
        close.contentTintColor = .white
        close.toolTip = "关闭摄像头画中画"
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        close.setAccessibilityLabel("关闭摄像头画中画")
        close.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: preview.topAnchor, constant: 0),
            close.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 0),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44)
        ])
        window.contentView = preview
        self.preview = preview
        panel = window
        window.orderFrontRegardless()
    }

    /// Removes the preview layer's session and panel without stopping the core-owned camera.
    func close() {
        preview?.previewLayer.session = nil
        preview = nil
        let old = panel
        panel = nil
        old?.orderOut(nil)
        old?.contentView = nil
        old?.close()
    }

    @objc private func userClose() { close(); onClose?() }
}

@MainActor
private final class CameraPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        setAccessibilityLabel("摄像头实时画面")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        var frame = window.frame
        let width = min(320, max(120, frame.width * max(0.5, 1 + event.magnification)))
        let size = CGSize(width: width, height: width * 9 / 16)
        frame.origin.x += (frame.width - size.width) / 2
        frame.origin.y += (frame.height - size.height) / 2
        frame.size = size
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        window.setFrame(frame, display: true)
    }
}
