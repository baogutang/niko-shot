// Stores immutable screen snapshots only for the lifetime of a capture session.
import CoreGraphics

struct FrozenFrame: Sendable {
    let screen: ScreenGeometry
    let image: CGImage
}

@MainActor
final class FreezeFrameStore {
    private(set) var frames: [UInt32: FrozenFrame] = [:]
    /// Replaces all snapshots atomically after successful capture.
    func replace(_ frames: [FrozenFrame]) { self.frames = Dictionary(uniqueKeysWithValues: frames.map { ($0.screen.id, $0) }) }
    /// Releases full-screen image references at session end.
    func clear() { frames.removeAll() }
}
