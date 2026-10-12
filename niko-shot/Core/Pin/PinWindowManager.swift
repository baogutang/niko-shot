// Manages independent persistent pinned captures and event-driven floating image windows.
import AppKit
import ImageIO
import Observation

struct PinEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let url: URL
    let thumbnail: Data
}

@MainActor @Observable
final class PinWindowManager {
    private(set) var pins: [PinEntry] = []
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let persistence = PinPersistence()
    @ObservationIgnored private var revision = 0

    /// Loads only lightweight library metadata; full images are decoded when opened.
    func load() {
        guard !loaded else { return }; loaded = true
        loadTask = Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { () -> [PinEntry] in
                guard let data = try? Data(contentsOf: AppPaths.pins.appendingPathComponent("index.json")), let decoded = try? JSONDecoder().decode([PinEntry].self, from: data) else { return [] }
                return decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            }.value
            self?.pins = entries
        }
    }
    /// Copies a capture into the pin library so history retention cannot remove it.
    func pin(image: CGImage, url: URL, thumbnail: Data) {
        load()
        let entry = PinEntry(id: UUID(), url: AppPaths.pins.appendingPathComponent("\(UUID().uuidString).png"), thumbnail: thumbnail)
        Task { [weak self] in
            do {
                await self?.loadTask?.value
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: AppPaths.pins, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: entry.url)
                }.value
                guard let self else { return }
                self.pins.insert(entry, at: 0); self.persist(); self.present(image, id: entry.id)
            } catch { ErrorPresenter.show(error) }
        }
    }
    func show(id: UUID) {
        if let window = windows[id] { window.orderFrontRegardless(); return }
        guard let entry = pins.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }; return image
                }.value
                self?.present(image, id: id)
            } catch { ErrorPresenter.show(error) }
        }
    }
    private func present(_ image: CGImage, id: UUID) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = max(CGFloat(image.width) / (screen.width * 0.65), CGFloat(image.height) / (screen.height * 0.65), 1)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true; window.hasShadow = true
        let view = PinImageView(); view.image = NSImage(cgImage: image, size: .zero); view.imageScaling = .scaleProportionallyUpOrDown
        view.closeAction = { [weak self] in self?.windows[id]?.close(); self?.windows.removeValue(forKey: id) }
        view.setAccessibilityLabel("贴图，双指缩放，滚轮调整透明度，双击关闭")
        window.contentView = view; window.center(); windows[id] = window
        if visible { window.orderFrontRegardless() }
    }
    func remove(id: UUID) {
        windows[id]?.close(); windows.removeValue(forKey: id)
        if let entry = pins.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: entry.url) }
        pins.removeAll { $0.id == id }; persist()
    }
    func toggleVisibility() { visible.toggle(); for window in windows.values { if visible { window.orderFrontRegardless() } else { window.orderOut(nil) } } }
    func closeAll() { for window in windows.values { window.close() }; windows.removeAll() }
    private func persist() {
        let entries = pins; revision += 1; let version = revision, writer = persistence
        Task { do { try await writer.save(entries, revision: version) } catch { ErrorPresenter.show(error) } }
    }
}

private actor PinPersistence {
    private var writtenRevision = 0
    func save(_ entries: [PinEntry], revision: Int) throws {
        guard revision > writtenRevision else { return }
        try FileManager.default.createDirectory(at: AppPaths.pins, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: AppPaths.pins.appendingPathComponent("index.json"), options: .atomic)
        writtenRevision = revision
    }
}

private final class PinImageView: NSImageView {
    var closeAction: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { closeAction?() } else { super.mouseDown(with: event) } }
    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let factor = max(0.5, 1 + event.magnification)
        var frame = window.frame
        let size = CGSize(width: min(4096, max(32, frame.width * factor)), height: min(4096, max(32, frame.height * factor)))
        frame.origin.x += (frame.width - size.width) / 2; frame.origin.y += (frame.height - size.height) / 2; frame.size = size
        window.setFrame(frame, display: true)
    }
    override func scrollWheel(with event: NSEvent) { if let window { window.alphaValue = min(1, max(0.15, window.alphaValue + event.scrollingDeltaY * 0.008)) } }
}
