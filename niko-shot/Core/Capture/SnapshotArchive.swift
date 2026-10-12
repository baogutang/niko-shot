// Spills the starting screen's immutable freeze frame to disk while annotating a smaller crop.
import Foundation
import ImageIO

struct ArchivedFrame: Sendable {
    let screen: ScreenGeometry
    let url: URL
}

enum SnapshotArchive {
    /// Writes an original snapshot on a worker without changing the captured world.
    static func write(_ frame: FrozenFrame) throws -> ArchivedFrame {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-freeze-\(UUID().uuidString).png")
        try ImageUtilities.png(frame.image).write(to: url, options: .atomic)
        return ArchivedFrame(screen: frame.screen, url: url)
    }
    /// Restores the same frozen frame when Tab returns to region selection.
    static func read(_ frame: ArchivedFrame) throws -> FrozenFrame {
        guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }
        return FrozenFrame(screen: frame.screen, image: image)
    }
}
