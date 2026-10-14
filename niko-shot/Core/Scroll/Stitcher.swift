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
    /// Keeps localized text motion visible without letting the surrounding blank page dilute it.
    public func normalizedDifference(to other: StitchSignature) -> Float {
        guard width == other.width, height == other.height, values.count == other.values.count, !values.isEmpty else { return 1 }
        let differences = values.indices.map { abs(values[$0] - other.values[$0]) }.sorted(by: >)
        // Average an upper tail rather than one maximum pixel, so subpixel raster jitter stays small.
        let count = max(1, (differences.count + 49) / 50)
        return min(1, max(0, differences.prefix(count).reduce(0, +) / Float(count)))
    }
}

struct StitchFrameAnalysis: Sendable {
    let width: Int, height: Int, sampleWidth: Int, bandHeight: Int
    let topInset: Int, bottomInset: Int
    let top: [Float], bottom: [Float]
    let profileWidth: Int, profileHeight: Int
    let profile: [Float]
    let signature: StitchSignature
    var residentBytes: Int { (top.count + bottom.count + profile.count + 4_096) * MemoryLayout<Float>.size }
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

    /// Searches the viewport for forward or backward overlap; repeated patterns require confirmation.
    public static func match(previous: CGImage, current: CGImage, ignoringTop: Int = 0,
                             ignoringBottom: Int = 0) throws -> StitchMatch {
        try match(previous: analyze(previous, top: ignoringTop, bottom: ignoringBottom),
                  current: analyze(current, top: ignoringTop, bottom: ignoringBottom),
                  currentImage: current, ignoringTop: ignoringTop)
    }

    static func analyze(_ image: CGImage, top: Int, bottom: Int) throws -> StitchFrameAnalysis {
        let rect = try contentRect(image, top: top, bottom: bottom)
        let height = Int(rect.height), bandHeight = min(200, height), width = min(256, image.width)
        // Spend the fixed sample budget on native rows before columns: vertically reducing text
        // can hide odd small movements. Extremely tall inputs still use a bounded coarse map.
        let profileHeight = min(65_536, height)
        let profileWidth = min(32, image.width, max(1, 65_536 / profileHeight))
        let profile = try luminance(image, crop: rect, width: profileWidth, height: profileHeight)
        let topInset = informativeBandInset(profile, width: profileWidth, height: profileHeight,
                                           nativeHeight: height, bandHeight: bandHeight, backward: true)
        let bottomInset = informativeBandInset(profile, width: profileWidth, height: profileHeight,
                                              nativeHeight: height, bandHeight: bandHeight, backward: false)
        let upper = CGRect(x: 0, y: rect.minY + CGFloat(topInset), width: CGFloat(image.width), height: CGFloat(bandHeight))
        let lower = CGRect(x: 0, y: rect.maxY - CGFloat(bottomInset + bandHeight), width: CGFloat(image.width), height: CGFloat(bandHeight))
        return try StitchFrameAnalysis(width: image.width, height: height, sampleWidth: width, bandHeight: bandHeight,
            topInset: topInset, bottomInset: bottomInset,
            top: luminance(image, crop: upper, width: width, height: bandHeight),
            bottom: luminance(image, crop: lower, width: width, height: bandHeight),
            profileWidth: profileWidth, profileHeight: profileHeight,
            profile: profile,
            signature: signature(for: image, ignoringTop: top, ignoringBottom: bottom))
    }

    private struct Candidate {
        let overlap: Int
        let score: Float
        let backward: Bool
    }

    private struct ReferenceWindow {
        let offset: Int, distance: Int
        let sum: Float, variance: Float
    }

    /// Detects stationary edge chrome before committing a second viewport. Blank page margins
    /// are deliberately insufficient: an edge must contain stationary detail and moving body rows.
    static func stationaryBands(previous: StitchFrameAnalysis, current: StitchFrameAnalysis) -> (top: Int, bottom: Int) {
        guard previous.width == current.width, previous.height == current.height,
              previous.profileHeight == previous.height, current.profileHeight == current.height,
              previous.profileWidth == current.profileWidth else { return (0, 0) }
        let columns = previous.profileWidth, rows = previous.height
        func stationary(_ row: Int) -> Bool {
            let offset = row * columns
            var difference: Float = 0
            for column in 0..<columns { difference += abs(previous.profile[offset + column] - current.profile[offset + column]) }
            return difference / Float(columns) <= 0.003
        }
        guard (0..<rows).filter({ !stationary($0) }).count >= 4 else { return (0, 0) }
        func edge(backward: Bool) -> Int {
            var lastDetail = 0, detailedRows = 0, stationaryRows = 0
            for distance in 0..<(rows / 3) {
                let row = backward ? rows - 1 - distance : distance
                guard stationary(row) else { break }
                stationaryRows = distance + 1
                let offset = row * columns
                var detail: Float = 0
                if distance > 0 {
                    let neighbor = (backward ? row + 1 : row - 1) * columns
                    for column in 0..<columns {
                        let value = previous.profile[offset + column] - previous.profile[neighbor + column]
                        detail += value * value
                    }
                }
                // Compositor dithering on near-white paper is stationary too. Its one/two-step
                // noise must not count as toolbar detail or consume blank document margins.
                if detail > Float(columns) * 0.000_1 { lastDetail = distance + 1; detailedRows += 1 }
            }
            // A vertical window border also crosses blank paper. Only changing rows establish
            // chrome, and a long uniform suffix belongs to the page from its first row onward.
            if stationaryRows - lastDetail >= 8 { lastDetail = max(0, lastDetail - 1) }
            return detailedRows >= 4 && lastDetail >= 8 ? lastDetail : 0
        }
        return (edge(backward: false), edge(backward: true))
    }

    static func match(previous: StitchFrameAnalysis, current: StitchFrameAnalysis,
                      currentImage: CGImage, ignoringTop: Int) throws -> StitchMatch {
        guard previous.width == current.width, previous.sampleWidth == current.sampleWidth else { throw ScrollCaptureError.changedWidth }
        let maximum = min(previous.height, current.height) - 1
        guard maximum >= 80 else { return StitchMatch(overlap: max(0, maximum / 2), correlation: 0, isAmbiguous: true) }
        try Task.checkCancellation()
        let stride = max(1, (max(previous.height, current.height) + 65_535) / 65_536)
        let columns = min(previous.profileWidth, current.profileWidth)
        let previousRows = previous.height / stride, currentRows = current.height / stride
        let first = max(2, (80 + stride - 1) / stride)
        let previousMap = resampledColumns(
            resampledRows(previous.profile, width: previous.profileWidth, oldRows: previous.profileHeight, newRows: previousRows),
            rows: previousRows, oldWidth: previous.profileWidth, newWidth: columns)
        let currentMap = resampledColumns(
            resampledRows(current.profile, width: current.profileWidth, oldRows: current.profileHeight, newRows: currentRows),
            rows: currentRows, oldWidth: current.profileWidth, newWidth: columns)
        let previousEdges = verticalEdges(previousMap, width: columns, height: previousRows)
        let currentEdges = verticalEdges(currentMap, width: columns, height: currentRows)
        let coarse = try candidates(previous: pyramid(previousMap, width: columns, height: previousRows),
                                    previousRows: previousRows / 2,
                                    current: pyramid(currentMap, width: columns, height: currentRows), currentRows: currentRows / 2,
                                    columns: max(1, columns / 2), first: max(1, first / 2), band: 32,
                                    maximumBand: max(1, previousRows / 2))
        // Scan the narrow map at its original row phase as well. A pyramid alone can hide an odd
        // one-pixel shift in high-frequency text/noise; wide native verification is restricted to peaks.
        let scores = try candidates(previous: previousMap, previousRows: previousRows,
                                    current: currentMap, currentRows: currentRows, columns: columns, first: first, band: 64,
                                    maximumBand: previousRows)
        guard let global = scores.max(by: { $0.score < $1.score }) else {
            return StitchMatch(overlap: 0, correlation: 0, isAmbiguous: true)
        }
        let coarseBest = coarse.max(by: { $0.score < $1.score })
        let local = coarseBest.flatMap { peak in
            scores.filter { $0.backward == peak.backward && abs($0.overlap - peak.overlap * 2) <= 3 }
                .max(by: { $0.score < $1.score })
        } ?? global
        let chosen = global.score > local.score + 0.001 ? global : local
        var peaks = [chosen]
        for candidate in scores.sorted(by: { $0.score > $1.score }) {
            if peaks.count == 8 { break }
            if peaks.allSatisfy({ $0.backward != candidate.backward || abs($0.overlap - candidate.overlap) >= 4 }) {
                peaks.append(candidate)
            }
        }
        var verified: [Candidate] = []
        let radius = stride == 1 ? 0 : stride * 2
        for peak in peaks {
            let center = peak.overlap * stride
            for overlap in max(80, center - radius)...min(maximum, center + radius) {
                try Task.checkCancellation()
                let inset = peak.backward ? previous.topInset : previous.bottomInset
                let rows = min(previous.bandHeight, current.bandHeight, overlap - inset)
                guard rows > 1 else {
                    verified.append(Candidate(overlap: overlap, score: 0, backward: peak.backward))
                    continue
                }
                let firstRow = peak.backward ? current.height - overlap + inset : overlap - inset - rows
                let patch = try luminance(currentImage,
                    crop: CGRect(x: 0, y: ignoringTop + firstRow, width: current.width, height: rows),
                    width: previous.sampleWidth, height: rows)
                let reference = peak.backward ? previous.top : previous.bottom
                let offset = peak.backward ? 0 : (previous.bandHeight - rows) * previous.sampleWidth
                let detail = ncc(reference, offset: offset, patch, offset: 0, count: rows * previous.sampleWidth)
                let agreement = distributedAgreement(previousEdges, previousRows: previousRows,
                    currentEdges, currentRows: currentRows, columns: columns,
                    overlap: max(2, overlap / stride), backward: peak.backward)
                let score = min(detail, agreement)
                verified.append(Candidate(overlap: overlap, score: score, backward: peak.backward))
            }
        }
        guard let best = verified.max(by: { $0.score < $1.score }) else {
            return StitchMatch(overlap: chosen.overlap * stride, correlation: 0, isAmbiguous: true)
        }
        let distant = verified.filter { $0.backward != best.backward || abs($0.overlap - best.overlap) >= 4 }
            .map(\.score).max() ?? -1
        let ambiguous = best.score < 0.05 || (distant > 0.8 && best.score - distant < 0.012)
        return StitchMatch(overlap: best.overlap, correlation: max(0, min(1, best.score)),
                           isAmbiguous: ambiguous, isBacktracking: best.backward)
    }

    private static func candidates(previous: [Float], previousRows: Int, current: [Float], currentRows: Int,
                                   columns: Int, first: Int, band: Int, maximumBand: Int) throws -> [Candidate] {
        let maximum = min(previousRows, currentRows) - 1
        guard maximum >= first else { return [] }
        let rows = min(band, first), count = rows * columns
        let forward = preferredWindows(previous, width: columns, height: previousRows, rows: rows,
                                       maximumBand: maximumBand, backward: false)
        let backward = preferredWindows(previous, width: columns, height: previousRows, rows: rows,
                                        maximumBand: maximumBand, backward: true)
        var scores: [Candidate] = []
        scores.reserveCapacity((maximum - first + 1) * 2)
        for overlap in first...maximum {
            if overlap.isMultiple(of: 64) { try Task.checkCancellation() }
            let a = forward[min(forward.count - 1, overlap - rows)]
            let b = backward[min(backward.count - 1, overlap - rows)]
            scores.append(Candidate(overlap: overlap,
                score: ncc(previous, reference: a, current, offset: (overlap - rows - a.distance) * columns,
                           count: count), backward: false))
            scores.append(Candidate(overlap: overlap,
                score: ncc(previous, reference: b, current, offset: (currentRows - overlap + b.distance) * columns,
                           count: count), backward: true))
        }
        return scores
    }

    private static func preferredWindows(_ values: [Float], width: Int, height: Int, rows: Int,
                                         maximumBand: Int, backward: Bool) -> [ReferenceWindow] {
        let limit = min(height, max(rows, maximumBand)) - rows, count = rows * width
        var choices: [ReferenceWindow] = []
        var best: ReferenceWindow?
        for distance in 0...limit {
            let offset = (backward ? distance : height - rows - distance) * width
            var sum: Float = 0, squares: Float = 0
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_sve(base.advanced(by: offset), 1, &sum, vDSP_Length(count))
                vDSP_svesq(base.advanced(by: offset), 1, &squares, vDSP_Length(count))
            }
            let candidate = ReferenceWindow(offset: offset, distance: distance, sum: sum,
                variance: max(0, squares - sum * sum / Float(count)))
            if best == nil || candidate.variance > (best?.variance ?? 0) { best = candidate }
            if let best { choices.append(best) }
        }
        return choices
    }

    private static func informativeBandInset(_ values: [Float], width: Int, height: Int,
                                             nativeHeight: Int, bandHeight: Int, backward: Bool) -> Int {
        let rows = max(1, min(height, bandHeight * height / nativeHeight)), count = rows * width
        let limit = height - rows
        func variance(at distance: Int) -> Float {
            let offset = (backward ? distance : height - rows - distance) * width
            var sum: Float = 0, squares: Float = 0
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_sve(base.advanced(by: offset), 1, &sum, vDSP_Length(count))
                vDSP_svesq(base.advanced(by: offset), 1, &squares, vDSP_Length(count))
            }
            return max(0, squares - sum * sum / Float(count))
        }
        var bestVariance = variance(at: 0), bestDistance = 0
        // Keep existing edge verification whenever it contains identifiable detail.
        if bestVariance > Float(count) * 0.000_01 { return 0 }
        for distance in stride(from: 0, through: limit, by: max(1, rows / 4)) {
            let value = variance(at: distance)
            if value > bestVariance { bestVariance = value; bestDistance = distance }
        }
        if variance(at: limit) > bestVariance { bestDistance = limit }
        return min(nativeHeight - bandHeight, bestDistance * nativeHeight / height)
    }

    private static func ncc(_ first: [Float], reference: ReferenceWindow, _ second: [Float], offset b: Int, count: Int) -> Float {
        guard reference.variance > Float(count) * 0.000_01, b >= 0, b + count <= second.count else { return 0 }
        return first.withUnsafeBufferPointer { firstBuffer in second.withUnsafeBufferPointer { secondBuffer in
            guard let x = firstBuffer.baseAddress?.advanced(by: reference.offset),
                  let y = secondBuffer.baseAddress?.advanced(by: b) else { return Float(0) }
            var sum: Float = 0, squares: Float = 0, dot: Float = 0
            let n = vDSP_Length(count)
            vDSP_sve(y, 1, &sum, n); vDSP_svesq(y, 1, &squares, n); vDSP_dotpr(x, 1, y, 1, &dot, n)
            let variance = max(0, squares - sum * sum / Float(count))
            guard variance > Float(count) * 0.000_01 else { return 0 }
            return (dot - reference.sum * sum / Float(count)) / sqrt(reference.variance * variance)
        } }
    }

    private static func resampledRows(_ values: [Float], width: Int, oldRows: Int, newRows: Int) -> [Float] {
        guard oldRows != newRows else { return values }
        var output = [Float](repeating: 0, count: width * newRows)
        for row in 0..<newRows {
            let position = (Double(row) + 0.5) * Double(oldRows) / Double(newRows) - 0.5
            let lower = max(0, min(oldRows - 1, Int(position.rounded(.down))))
            let upper = min(oldRows - 1, lower + 1)
            let fraction = Float(max(0, min(1, position - Double(lower))))
            for column in 0..<width {
                output[row * width + column] = values[lower * width + column] * (1 - fraction) + values[upper * width + column] * fraction
            }
        }
        return output
    }

    private static func resampledColumns(_ values: [Float], rows: Int, oldWidth: Int, newWidth: Int) -> [Float] {
        guard oldWidth != newWidth else { return values }
        var output = [Float](repeating: 0, count: rows * newWidth)
        for column in 0..<newWidth {
            let position = (Double(column) + 0.5) * Double(oldWidth) / Double(newWidth) - 0.5
            let lower = max(0, min(oldWidth - 1, Int(position.rounded(.down))))
            let upper = min(oldWidth - 1, lower + 1)
            let fraction = Float(max(0, min(1, position - Double(lower))))
            for row in 0..<rows {
                output[row * newWidth + column] = values[row * oldWidth + lower] * (1 - fraction) + values[row * oldWidth + upper] * fraction
            }
        }
        return output
    }

    private static func contentRect(_ image: CGImage, top: Int, bottom: Int) throws -> CGRect {
        guard image.width > 0, image.height > 0, top >= 0, bottom >= 0,
              top < image.height, bottom < image.height - top else { throw ScrollCaptureError.invalidBands }
        return CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom)
    }

    private static func verticalEdges(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard height > 1 else { return [] }
        return (0..<((height - 1) * width)).map { values[$0 + width] - values[$0] }
    }

    private static func distributedAgreement(_ previous: [Float], previousRows: Int,
                                             _ current: [Float], currentRows: Int,
                                             columns: Int, overlap: Int, backward: Bool) -> Float {
        let sharedRows = min(overlap, previousRows, currentRows) - 1
        guard sharedRows > 1 else { return 0 }
        let previousStart = backward ? 0 : previousRows - overlap
        let currentStart = backward ? currentRows - overlap : 0
        var informativeRows = 0
        for row in 0..<sharedRows {
            let left = (previousStart + row) * columns, right = (currentStart + row) * columns
            if max(signalEnergy(previous, offset: left, count: columns),
                   signalEnergy(current, offset: right, count: columns)) > Float(columns) * 0.000_01 {
                informativeRows += 1
                if informativeRows >= 4 { break }
            }
        }
        // A single separator has two identical edge rows and cannot establish a unique seam.
        guard informativeRows >= 4 else { return 0 }
        var agreements: [Float] = []
        for part in 0..<4 {
            let firstRow = sharedRows * part / 4, lastRow = sharedRows * (part + 1) / 4
            let count = (lastRow - firstRow) * columns
            let a = (previousStart + firstRow) * columns, b = (currentStart + firstRow) * columns
            guard count > 1, a >= 0, b >= 0, a + count <= previous.count, b + count <= current.count else { continue }
            // Empty regions add no evidence. Detail present in only one frame is a contradiction.
            let left = signalVariance(previous, offset: a, count: count)
            let right = signalVariance(current, offset: b, count: count)
            if max(left, right) <= Float(count) * 0.000_01 { continue }
            agreements.append(ncc(previous, offset: a, current, offset: b, count: count))
        }
        return agreements.min() ?? 0
    }

    private static func signalVariance(_ values: [Float], offset: Int, count: Int) -> Float {
        var sum: Float = 0, squares: Float = 0
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_sve(base.advanced(by: offset), 1, &sum, vDSP_Length(count))
            vDSP_svesq(base.advanced(by: offset), 1, &squares, vDSP_Length(count))
        }
        return max(0, squares - sum * sum / Float(count))
    }

    private static func signalEnergy(_ values: [Float], offset: Int, count: Int) -> Float {
        var squares: Float = 0
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_svesq(base.advanced(by: offset), 1, &squares, vDSP_Length(count))
        }
        return squares
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
