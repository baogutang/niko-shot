// Converts global AppKit points, flipped screen-local points and image pixels without global DPI assumptions.
import CoreGraphics

/// Immutable geometry for one display, including its notch-safe inset.
struct ScreenGeometry: Sendable, Equatable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
    var safeTop: CGFloat = 0

    var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    var safeBounds: CGRect { CGRect(x: 0, y: safeTop, width: frame.width, height: max(0, frame.height - safeTop)) }
}

enum CoordinateSpace {
    /// Returns flipped, top-left screen-local points from an AppKit global point.
    static func globalPointToScreenLocal(_ point: CGPoint, screen: ScreenGeometry) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
    }

    /// Converts flipped local points to that display's backing pixels.
    static func screenLocalToImagePixel(_ point: CGPoint, screen: ScreenGeometry) -> CGPoint {
        CGPoint(x: point.x * screen.scale, y: point.y * screen.scale)
    }

    /// Aligns selection edges to pixels and clamps them to the frozen image.
    static func imagePixelRect(fromSelection rect: CGRect, screen: ScreenGeometry) -> CGRect {
        let clipped = rect.standardized.intersection(screen.localBounds)
        guard !clipped.isNull, screen.scale > 0 else { return .zero }
        let left = (clipped.minX * screen.scale).rounded()
        let top = (clipped.minY * screen.scale).rounded()
        let right = (clipped.maxX * screen.scale).rounded()
        let bottom = (clipped.maxY * screen.scale).rounded()
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Flips a global y coordinate around the primary display's top edge.
    static func flippedY(_ y: CGFloat, primaryTop: CGFloat) -> CGFloat { primaryTop - y }

    /// Converts ScreenCaptureKit's global top-left rectangle to AppKit global points.
    static func windowToAppKit(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: flippedY(rect.maxY, primaryTop: primaryTop), width: rect.width, height: rect.height)
    }

    /// Returns the AppKit global rectangle for a flipped local selection.
    static func localToGlobal(_ rect: CGRect, screen: ScreenGeometry) -> CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
