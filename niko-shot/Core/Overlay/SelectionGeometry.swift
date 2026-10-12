// Implements pure selection resizing math so keyboard and mouse behavior share testable rules.
import CoreGraphics

enum SelectionGeometry {
    /// Builds a rectangle with optional aspect lock and center anchoring.
    static func drag(anchor: CGPoint, point: CGPoint, aspect: CGFloat?, centered: Bool) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if let aspect, aspect > 0 {
            if abs(dx) / max(abs(dy), 0.001) > aspect { dy = abs(dx) / aspect * (dy < 0 ? -1 : 1) }
            else { dx = abs(dy) * aspect * (dx < 0 ? -1 : 1) }
        }
        if centered { return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2) }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }
    /// Clamps position and size while retaining a rectangle within its starting display.
    static func clamp(_ rect: CGRect, bounds: CGRect) -> CGRect {
        let width = min(max(1, rect.width), bounds.width)
        let height = min(max(1, rect.height), bounds.height)
        return CGRect(x: min(max(bounds.minX, rect.minX), bounds.maxX - width), y: min(max(bounds.minY, rect.minY), bounds.maxY - height), width: width, height: height)
    }
    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    /// Resizes all eight handles, mirroring the opposite edge when Option is held.
    static func resize(_ rect: CGRect, handle: Int, to point: CGPoint, aspect: CGFloat?, centered: Bool) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if [0, 6, 7].contains(handle) { left = point.x; if centered { right = 2 * rect.midX - left } }
        if [2, 3, 4].contains(handle) { right = point.x; if centered { left = 2 * rect.midX - right } }
        if [0, 1, 2].contains(handle) { top = point.y; if centered { bottom = 2 * rect.midY - top } }
        if [4, 5, 6].contains(handle) { bottom = point.y; if centered { top = 2 * rect.midY - bottom } }
        var result = CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
        if let aspect, aspect > 0 {
            if handle == 1 || handle == 5 {
                let width = result.height * aspect; result.origin.x = rect.midX - width / 2; result.size.width = width
            } else if handle == 3 || handle == 7 {
                let height = result.width / aspect; result.origin.y = rect.midY - height / 2; result.size.height = height
            } else {
                let anchor = centered ? CGPoint(x: rect.midX, y: rect.midY) : handles(rect)[(handle + 4) % 8]
                result = drag(anchor: anchor, point: point, aspect: aspect, centered: centered)
            }
        }
        return result
    }
}
