// Builds a bounded thumbnail from the same accepted rows as the disk-backed final image.
import CoreGraphics
import Foundation

/// The complete accepted long image, at preview resolution; source dimensions remain exact.
public struct ScrollPreviewSnapshot: Sendable {
    public let image: CGImage
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let frames: Int
}

/// Owned by the serial stitch actor. It never decodes the full-resolution assembled document.
struct ScrollPreviewAccumulator {
    static let maximumWidth = 384
    static let maximumHeight = 8_192
    static let maximumPixels = 2_097_152
    private(set) var snapshot: ScrollPreviewSnapshot?
    var residentBufferBytes: Int { snapshot.map { $0.image.bytesPerRow * $0.image.height } ?? 0 }

    /// Called only after the writer commits an accepted segment. Rejected candidates never enter it.
    mutating func append(_ image: CGImage, firstRow: Int, rows: Int, sourceHeight: Int, frames: Int) throws {
        try Task.checkCancellation()
        guard rows > 0, firstRow >= 0, firstRow <= image.height - rows,
              sourceHeight >= rows, frames > 0,
              snapshot.map({ $0.sourceWidth == image.width && $0.sourceHeight == sourceHeight - rows })
                ?? (sourceHeight == rows),
              let segment = image.cropping(to: CGRect(x: 0, y: firstRow, width: image.width, height: rows)) else {
            throw ScrollCaptureError.image
        }
        let size = Self.dimensions(width: image.width, height: sourceHeight)
        guard let canvas = CGContext(data: nil, width: size.width, height: size.height,
            bitsPerComponent: 8, bytesPerRow: size.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScrollCaptureError.image
        }
        canvas.interpolationQuality = .high
        let precedingHeight = snapshot.map {
            min(size.height, Int((Double($0.sourceHeight) / Double(sourceHeight) * Double(size.height)).rounded()))
        } ?? 0
        if let snapshot, precedingHeight > 0 {
            canvas.draw(snapshot.image, in: CGRect(x: 0, y: size.height - precedingHeight,
                width: size.width, height: precedingHeight))
        }
        let appendedHeight = size.height - precedingHeight
        if appendedHeight > 0 {
            canvas.draw(segment, in: CGRect(x: 0, y: 0, width: size.width, height: appendedHeight))
        }
        try Task.checkCancellation()
        guard let assembled = canvas.makeImage() else { throw ScrollCaptureError.image }
        snapshot = ScrollPreviewSnapshot(image: assembled, sourceWidth: image.width, sourceHeight: sourceHeight, frames: frames)
    }

    private static func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height),
                        sqrt(Double(maximumPixels) / (Double(width) * Double(height))))
        var columns = max(1, Int((Double(width) * scale).rounded(.down)))
        var rows = max(1, min(maximumHeight, Int((Double(height) * Double(columns) / Double(width)).rounded())))
        while columns * rows > maximumPixels, columns > 1 {
            columns -= 1
            rows = max(1, min(maximumHeight, Int((Double(height) * Double(columns) / Double(width)).rounded())))
        }
        return (columns, rows)
    }
}
