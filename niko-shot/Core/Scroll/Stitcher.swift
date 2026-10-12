// Matches pixel overlaps using Accelerate NCC, a coarse image pyramid and one-pixel refinement.
import Accelerate
import CoreGraphics
import Foundation

/// A bounded luminance sample used for stable-frame and duplicate detection.
public struct StitchSignature: Sendable {
    public let width: Int
    public let height: Int
    private let values: [Float]
    init(width: Int, height: Int, values: [Float]) { self.width = width; self.height = height; self.values = values }
    /// Returns normalized absolute luminance difference; shape changes always return one.
    public func normalizedDifference(to other: StitchSignature) -> Float {
        guard width == other.width, height == other.height, values.count == other.values.count, !values.isEmpty else { return 1 }
        var difference: Float = 0
        for index in values.indices { difference += abs(values[index] - other.values[index]) }
        return min(1, max(0, difference / Float(values.count)))
    }
}

struct StitchFrameAnalysis: Sendable {
    let width: Int, height: Int, sampleWidth: Int, bandHeight: Int
    let top: [Float], bottom: [Float]
    let signature: StitchSignature
    var residentBytes: Int { (top.count + bottom.count + 4_096) * MemoryLayout<Float>.size }
}

/// Pure CPU image-analysis routines; invoke them on a worker task or the scroll session actor.
public enum Stitcher {
    /// Samples the content after trimming fixed chrome, without retaining a source CGImage.
    public static func signature(for image: CGImage, ignoringTop: Int = 0, ignoringBottom: Int = 0) throws -> StitchSignature {
        let rect = try contentRect(image, top: ignoringTop, bottom: ignoringBottom)
        let sampleWidth = min(64, image.width), sampleHeight = min(64, Int(rect.height))
        let values = try luminance(image, crop: rect, width: sampleWidth, height: sampleHeight)
        return StitchSignature(width: image.width, height: Int(rect.height), values: values)
    }

    /// Estimates an 80–200 pixel content overlap; repeated patterns are marked ambiguous.
    public static func match(previous: CGImage, current: CGImage, ignoringTop: Int = 0,
                             ignoringBottom: Int = 0) throws -> StitchMatch {
        try match(previous: analyze(previous, top: ignoringTop, bottom: ignoringBottom),
                  current: analyze(current, top: ignoringTop, bottom: ignoringBottom))
    }

    static func analyze(_ image: CGImage, top: Int, bottom: Int) throws -> StitchFrameAnalysis {
        let rect = try contentRect(image, top: top, bottom: bottom)
        let height = Int(rect.height), bandHeight = min(200, height), width = min(256, image.width)
        let upper = CGRect(x: 0, y: rect.minY, width: CGFloat(image.width), height: CGFloat(bandHeight))
        let lower = CGRect(x: 0, y: rect.maxY - CGFloat(bandHeight), width: CGFloat(image.width), height: CGFloat(bandHeight))
        return try StitchFrameAnalysis(width: image.width, height: height, sampleWidth: width, bandHeight: bandHeight,
            top: luminance(image, crop: upper, width: width, height: bandHeight),
            bottom: luminance(image, crop: lower, width: width, height: bandHeight),
            signature: signature(for: image, ignoringTop: top, ignoringBottom: bottom))
    }

    static func match(previous: StitchFrameAnalysis, current: StitchFrameAnalysis) throws -> StitchMatch {
        guard previous.width == current.width, previous.sampleWidth == current.sampleWidth else { throw ScrollCaptureError.changedWidth }
        let maximum = min(200, previous.height - 1, current.height - 1)
        guard maximum >= 80 else { return StitchMatch(overlap: max(0, maximum / 2), correlation: 0, isAmbiguous: true) }
        let first = 80, columns = previous.sampleWidth
        let coarsePrevious = pyramid(previous.bottom, width: columns, height: previous.bandHeight)
        let coarseCurrent = pyramid(current.top, width: columns, height: current.bandHeight)
        let coarseWidth = max(1, columns / 2), coarseHeight = previous.bandHeight / 2
        var coarseBest = first, coarseScore: Float = -1
        for overlap in stride(from: first, through: maximum, by: 4) {
            let reduced = overlap / 2
            let score = ncc(coarsePrevious, offset: (coarseHeight - reduced) * coarseWidth,
                            coarseCurrent, offset: 0, count: reduced * coarseWidth)
            if score > coarseScore { coarseScore = score; coarseBest = overlap }
        }
        // A second coarse scan at full vertical resolution prevents a single-pixel high-frequency alias
        // from hiding the correct peak in the averaged pyramid.
        var scores: [(Int, Float)] = []
        for overlap in first...maximum {
            let score = ncc(previous.bottom, offset: (previous.bandHeight - overlap) * columns,
                            current.top, offset: 0, count: overlap * columns)
            scores.append((overlap, score))
        }
        let refinement = scores.filter { abs($0.0 - coarseBest) <= 5 }
        let local = refinement.max(by: { $0.1 < $1.1 }) ?? (first, 0)
        let global = scores.max(by: { $0.1 < $1.1 }) ?? local
        let best = global.1 > local.1 + 0.001 ? global : local
        let distant = scores.filter { abs($0.0 - best.0) >= 4 }.map(\.1).max() ?? -1
        let ambiguous = best.1 < 0.05 || (distant > 0.8 && best.1 - distant < 0.012)
        return StitchMatch(overlap: best.0, correlation: max(0, min(1, best.1)), isAmbiguous: ambiguous)
    }

    private static func contentRect(_ image: CGImage, top: Int, bottom: Int) throws -> CGRect {
        guard image.width > 0, image.height > 0, top >= 0, bottom >= 0,
              top < image.height, bottom < image.height - top else { throw ScrollCaptureError.invalidBands }
        return CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom)
    }

    private static func luminance(_ image: CGImage, crop: CGRect, width: Int, height: Int) throws -> [Float] {
        guard let section = image.cropping(to: crop),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ScrollCaptureError.image }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high; context.draw(section, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<(width * height)).map { index in
            (Float(bytes[index * 4]) * 0.2126 + Float(bytes[index * 4 + 1]) * 0.7152 + Float(bytes[index * 4 + 2]) * 0.0722) / 255
        }
    }

    private static func pyramid(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        let columns = max(1, width / 2), rows = height / 2
        var output = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows { for column in 0..<columns {
            let x = min(width - 1, column * 2), y = row * 2
            output[row * columns + column] = (pixels[y * width + x] + pixels[y * width + min(width - 1, x + 1)]
                + pixels[(y + 1) * width + x] + pixels[(y + 1) * width + min(width - 1, x + 1)]) / 4
        } }
        return output
    }

    private static func ncc(_ first: [Float], offset a: Int, _ second: [Float], offset b: Int, count: Int) -> Float {
        guard count > 1, a >= 0, b >= 0, a + count <= first.count, b + count <= second.count else { return 0 }
        return first.withUnsafeBufferPointer { firstBuffer in second.withUnsafeBufferPointer { secondBuffer in
            guard let x = firstBuffer.baseAddress?.advanced(by: a), let y = secondBuffer.baseAddress?.advanced(by: b) else { return Float(0) }
            var sumX: Float = 0, sumY: Float = 0, squareX: Float = 0, squareY: Float = 0, dot: Float = 0
            let n = vDSP_Length(count)
            vDSP_sve(x, 1, &sumX, n); vDSP_sve(y, 1, &sumY, n)
            vDSP_svesq(x, 1, &squareX, n); vDSP_svesq(y, 1, &squareY, n); vDSP_dotpr(x, 1, y, 1, &dot, n)
            let varianceX = max(0, squareX - sumX * sumX / Float(count))
            let varianceY = max(0, squareY - sumY * sumY / Float(count))
            guard varianceX > Float(count) * 0.000_01, varianceY > Float(count) * 0.000_01 else { return 0 }
            let result = (dot - sumX * sumY / Float(count)) / sqrt(varianceX * varianceY)
            return result.isFinite ? result : 0
        } }
    }
}
