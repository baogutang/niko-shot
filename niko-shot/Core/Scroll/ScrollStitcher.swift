// Stitches vertically scrolled viewports with tolerant luminance row matching and fixed-chrome trimming.
import CoreGraphics
import Foundation

/// One viewport reduced to sampled luminance rows. Only the newest accepted frame keeps its pixels.
struct ScrollFrame: Sendable {
    let image: CGImage
    let width: Int
    let height: Int
    /// Samples per row, taken away from window edges and overlay scroll bars.
    let samples: Int
    /// `height * samples` luminance values (0.30 R + 0.59 G + 0.11 B).
    let luma: [UInt8]
    /// Per-row horizontal gradient energy; flat rows carry no alignment evidence.
    let detail: [Int32]
    /// Per-row luminance sum, used by the coarse shift search.
    let mean: [Int32]
    /// Absolute pixel x of each sampled column, for mapping sample ranges back to pixels.
    let sampleX: [Int]

    /// Samples an image of any 8-bit RGB layout without changing its color space.
    init(_ image: CGImage, pixelsPerPoint: CGFloat = 2) throws {
        let width = image.width, height = image.height
        guard width >= 8, height >= 8, width <= 32_768, height <= 32_768 else { throw ScrollCaptureError.image }
        let scale = max(1, pixelsPerPoint.isFinite ? pixelsPerPoint : 2)
        // 左右边距避开窗口描边与 macOS 浮动滚动条（规格：各忽略约 20px）。
        let left = min(width / 8, max(4, Int(10 * scale)))
        let right = min(width / 6, max(6, Int(18 * scale)))
        let usable = max(1, width - left - right)
        let samples = min(usable, 512)
        var columns = [Int](repeating: 0, count: samples)
        for index in 0..<samples { columns[index] = left + (2 * index + 1) * usable / (2 * samples) }

        var luma = [UInt8](repeating: 0, count: height * samples)
        var detail = [Int32](repeating: 0, count: height)
        var mean = [Int32](repeating: 0, count: height)
        var sampleX = [Int](repeating: 0, count: samples)
        try Self.withBGRA(image) { base, bytesPerRow in
            luma.withUnsafeMutableBufferPointer { output in
                for row in 0..<height {
                    let line = base.advanced(by: row * bytesPerRow)
                    let target = row * samples
                    var sum: Int32 = 0, energy: Int32 = 0, previous: Int32 = -1
                    for index in 0..<samples {
                        let pixel = line.advanced(by: columns[index] * 4)
                        sampleX[index] = columns[index]
                        let value = (Int32(pixel[0]) * 29 + Int32(pixel[1]) * 150 + Int32(pixel[2]) * 77 + 128) >> 8
                        output[target + index] = UInt8(truncatingIfNeeded: value)
                        sum += value
                        if previous >= 0 { energy += abs(value - previous) }
                        previous = value
                    }
                    detail[row] = energy; mean[row] = sum
                }
            }
        }
        self.image = image; self.width = width; self.height = height; self.samples = samples
        self.luma = luma; self.detail = detail; self.mean = mean; self.sampleX = sampleX
    }

    /// Provides tightly addressed BGRA bytes, copying only when the source layout differs.
    private static func withBGRA(_ image: CGImage, _ body: (UnsafePointer<UInt8>, Int) throws -> Void) throws {
        let alpha = image.alphaInfo
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bitmapInfo.contains(.byteOrder32Little),
           [.premultipliedFirst, .noneSkipFirst, .first].contains(alpha),
           let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * image.height {
            try withExtendedLifetime(data) { try body(base, image.bytesPerRow) }
            return
        }
        let bytesPerRow = image.width * 4
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let pointer = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ScrollCaptureError.image }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try body(UnsafePointer(pointer), bytesPerRow)
    }

    /// Whether every sample in the frame has nearly the same brightness (blank or non-scrollable selection).
    var isUniform: Bool {
        guard let low = luma.min(), let high = luma.max() else { return true }
        return Int(high) - Int(low) <= 6
    }
}

/// Outcome of offering one viewport to the stitcher.
enum ScrollStitchResult: Sendable, Equatable {
    /// New rows were appended below the accepted content.
    case appended(rows: Int)
    /// The viewport has not moved since the last accepted frame.
    case unchanged
    /// The user scrolled back above the accepted tail; nothing is appended.
    case reversed
    /// No reliable overlap with the accepted tail (scrolled too fast or content is ambiguous).
    case unmatched
    /// The output reached its size limit; capture should finish.
    case limitReached
}

/// Matching parameters measured from real screen captures (spec 04 §8), expressed for sampled rows.
struct ScrollMatchParameters: Sendable {
    /// Per-sample luminance tolerance; anti-aliasing and color-managed compositing stay inside it.
    var tolerance: Int32 = 10
    /// Samples allowed outside the tolerance per row (blinking carets, tiny spinners).
    var outlierFraction = 0.012
    /// Largest share of informative overlap rows that may disagree at the true shift.
    var maximumMismatchRatio = 0.12
    /// Mismatch share allowed by the momentum-rescue pass. Sub-pixel scrolling renders rows
    /// resampled (soft), which fails strict row equality; only a precise scroll hint plus a
    /// lone winner may accept this wider ratio.
    var relaxedMismatchRatio = 0.38
    /// Smallest informative overlap for the momentum-rescue pass, as a share of the overlap.
    var relaxedMinimumEvidenceFraction = 0.16
    /// Absolute floor for that share, in rows.
    var relaxedMinimumEvidenceRows = 14
    /// How far the relaxed winner may sit from the precise scroll hint, in rows.
    var relaxedHintTolerance = 8
    /// A relaxed rival within this ratio margin makes the winner ambiguous.
    var relaxedRivalMargin = 0.06
    /// Smallest overlap, as a share of the scrolling body, accepted as evidence.
    var minimumOverlapFraction = 0.1
    /// Absolute smallest overlap in pixels.
    var minimumOverlapRows = 24
}

/// Pure, deterministic stitching state. A worker actor owns it; tests drive it directly.
struct ScrollStitcher {
    let parameters: ScrollMatchParameters
    let pixelsPerPoint: CGFloat
    let maximumHeight: Int
    let maximumPixels: Int
    private(set) var anchor: ScrollFrame?
    /// Accepted rows, top to bottom; each is an independent copy that never retains a whole viewport.
    private(set) var segments: [CGImage] = []
    /// Viewport row each segment was copied from, for mapping overlay blocks back onto output.
    private(set) var segmentOrigins: [Int] = []
    private(set) var contentHeight = 0
    private(set) var frames = 0
    /// Fixed footer rows trimmed from every viewport and appended once from the newest frame.
    private(set) var footerRows = 0
    private var headerRows = 0
    private var bandsLocked = false
    /// Row in `anchor` matching the last accepted output row.
    private var tailRow = 0
    /// Floating-overlay removal: blocks that stay put on screen while content moves underneath.
    /// A block votes when it matches the previous frame at the same screen position while
    /// differing from the document-aligned position; after enough votes it is erased from output.
    var overlayVotes: [Int: Int] = [:]   // internal for diagnostics
    private var overlayFills: [Int: (red: UInt8, green: UInt8, blue: UInt8)] = [:]
    /// Overlay grid width: samples per strip (≈ 90 px at the default 512-sample sampling).
    static let overlayStripSamples = 64
    /// Screen-still rows only vote when the content actually moved by this many rows.
    static let overlayMinimumShift = 8
    /// Distinct votes (accepted frames) before a row strip is treated as a floating overlay.
    static let overlayVoteThreshold = 3
    /// Set when early segments were rewritten (fixed footer discovered), so previews must rebuild.
    private(set) var didRewriteSegments = false

    var width: Int { anchor?.width ?? 0 }
    /// Final output height including the single fixed footer.
    var outputHeight: Int { contentHeight + footerRows }
    var viewportHeight: Int { anchor?.height ?? 0 }

    init(parameters: ScrollMatchParameters = ScrollMatchParameters(), pixelsPerPoint: CGFloat = 2,
         maximumHeight: Int = 60_000, maximumPixels: Int = 160_000_000) {
        self.parameters = parameters
        self.pixelsPerPoint = pixelsPerPoint
        self.maximumHeight = maximumHeight
        self.maximumPixels = maximumPixels
    }

    /// Offers a viewport. `hint` is the expected content shift in pixels from precise scroll deltas.
    mutating func add(_ image: CGImage, hint: Int? = nil) throws -> ScrollStitchResult {
        try add(ScrollFrame(image, pixelsPerPoint: pixelsPerPoint), hint: hint)
    }

    mutating func add(_ frame: ScrollFrame, hint: Int? = nil) throws -> ScrollStitchResult {
        didRewriteSegments = false
        guard let anchor else {
            let copy = try Self.copyRows(frame.image, from: 0, count: frame.height)
            segments = [copy]; segmentOrigins = [0]; contentHeight = frame.height; tailRow = frame.height - 1
            self.anchor = frame; frames = 1
            return .appended(rows: frame.height)
        }
        guard frame.width == anchor.width, frame.height == anchor.height, frame.samples == anchor.samples else {
            throw ScrollTargetError.windowResized
        }
        let height = frame.height
        let bands = Self.staticBands(anchor, frame, parameters: parameters)
        let minimumBody = max(parameters.minimumOverlapRows * 2, Int(Double(height) * 0.12))
        if bands.top + bands.bottom >= height - minimumBody { return .unchanged }

        let top = max(bands.top, bandsLocked ? headerRows : 0)
        let bottom = max(bands.bottom, bandsLocked ? footerRows : 0)
        guard height - top - bottom >= minimumBody else { return .unchanged }
        guard let shift = Self.shift(anchor: anchor, frame: frame, top: top, end: height - bottom,
                                     hint: hint, parameters: parameters) else { return .unmatched }
        if shift == 0 { return .unchanged }
        if shift < 0 { return .reversed }

        if !bandsLocked {
            // 固定区只在第一次真实移动时锁定；之后的帧只在匹配时额外排除新出现的静止条。
            bandsLocked = true
            headerRows = bands.top
            let footer = min(bands.bottom, height - 1 - shift)
            if footer > 0 {
                guard segments.count == 1, contentHeight == height else { throw ScrollCaptureError.image }
                segments[0] = try Self.copyRows(anchor.image, from: 0, count: height - footer)
                contentHeight = height - footer
                tailRow = height - 1 - footer
                didRewriteSegments = true
            }
            footerRows = footer
        }

        let end = height - footerRows
        let first = tailRow - shift + 1
        guard first >= 0, first < end else { return first >= end ? .unchanged : .unmatched }
        var count = end - first
        var limited = false
        let rowLimit = min(maximumHeight, maximumPixels / max(1, frame.width)) - footerRows
        if contentHeight + count > rowLimit {
            count = max(0, rowLimit - contentHeight); limited = true
        }
        // 悬浮层投票要在 anchor 还未被替换时做：同一屏幕位置仍在、文档对齐位置已变。
        Self.accumulateOverlayVotes(anchor: anchor, frame: frame, shift: shift, top: top, bottom: bottom,
                                    votes: &overlayVotes)
        if count > 0 {
            segments.append(try Self.copyRows(frame.image, from: first, count: count))
            segmentOrigins.append(first)
            contentHeight += count
        }
        self.anchor = frame
        tailRow = first + count - 1
        frames += 1
        return limited ? .limitReached : .appended(rows: count)
    }

    /// Draws the accepted rows and the single fixed footer into one image, erasing confirmed
    /// floating overlays (e.g. a chat app's "scroll to bottom" pill) with their surrounding fill.
    func makeImage() throws -> CGImage {
        guard let anchor, contentHeight > 0 else { throw ScrollCaptureError.noFrames }
        let total = outputHeight, width = anchor.width
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: anchor.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScrollCaptureError.dimensionOverflow
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        var offset = 0
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let segmentY = total - offset - segment.height
            context.draw(segment, in: CGRect(x: 0, y: segmentY, width: width, height: segment.height))
            drawOverlayErasures(in: context, segmentIndex: index, segmentY: segmentY, offset: offset, total: total)
            offset += segment.height
        }
        if footerRows > 0 {
            let footer = try Self.copyRows(anchor.image, from: anchor.height - footerRows, count: footerRows)
            context.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footerRows))
        }
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    // MARK: - Floating overlays

    private typealias OverlayKey = Int

    private static func overlayKey(row: Int, strip: Int) -> OverlayKey { row << 8 | strip }

    /// Compares one strip (row × stripSamples) between two frames with the standard outlier budget.
    private static func stripMatches(_ a: ScrollFrame, _ rowA: Int, _ stripA: Int,
                                     _ b: ScrollFrame, _ rowB: Int, _ stripB: Int) -> Bool {
        let width = Self.overlayStripSamples
        let allowed = max(2, width / 5)
        let tolerance = ScrollMatchParameters().tolerance
        let ia = (rowA * a.samples) + stripA * width
        let ib = (rowB * b.samples) + stripB * width
        var outliers = 0
        for s in 0..<width {
            if abs(Int32(a.luma[ia + s]) - Int32(b.luma[ib + s])) > tolerance {
                outliers += 1
                if outliers > allowed { return false }
            }
        }
        return true
    }

    /// 对每个「行 × 条带」投票：同一屏幕位置仍然相同（悬浮物没动），而文档对齐位置已经不同
    /// （内容在动）—— 判定为浮层。像素级重复的内容（如相同的头像）在文档对齐位置也相同，
    /// 不会被误判。这是逐行比较，对齐行是单行，不存在越界歧义。
    static func accumulateOverlayVotes(anchor: ScrollFrame, frame: ScrollFrame, shift: Int, top: Int, bottom: Int,
                                       votes: inout [Int: Int]) {
        guard shift >= Self.overlayMinimumShift else { return }
        let strips = anchor.samples / Self.overlayStripSamples
        guard strips > 0 else { return }
        // 固定带边缘 8 行内的静止条（阴影、分隔线）容易连续假匹配，不参与投票。
        for row in max(top, 0) + 8..<(frame.height - max(bottom, 0) - 8) {
            let aligned = row + shift
            guard aligned >= 0, aligned < frame.height else { continue }
            for strip in 0..<strips {
                let key = overlayKey(row: row, strip: strip)
                // 无对比度的空白条带不参与投票：它没有浮层证据，误票只会污染拼接结果。
                let s0 = strip * Self.overlayStripSamples
                var lo = Int32.max, hi = Int32.min
                for s in 0..<Self.overlayStripSamples {
                    let v = Int32(frame.luma[row * frame.samples + s0 + s])
                    lo = min(lo, v); hi = max(hi, v)
                }
                guard hi - lo >= 24 else { continue }
                guard Self.stripMatches(anchor, row, strip, frame, row, strip) else { continue }
                guard !Self.stripMatches(anchor, aligned, strip, frame, row, strip) else { continue }
                votes[key, default: 0] += 1
            }
        }
    }

    /// 把确认的浮层条带从输出里抹除：用条带上下若干行的逐通道中位色填充（保持背景色调）。
    private func drawOverlayErasures(in context: CGContext, segmentIndex: Int, segmentY: Int,
                                     offset: Int, total: Int) {
        guard !overlayVotes.isEmpty, segmentIndex < segmentOrigins.count else { return }
        guard let anchor, let data = context.data else { return }
        let origin = segmentOrigins[segmentIndex]
        let segmentHeight = segments[segmentIndex].height
        let strip = Self.overlayStripSamples
        let strips = anchor.samples / strip
        let bytesPerRow = context.bytesPerRow
        let base = data.assumingMemoryBound(to: UInt8.self)
        let threshold = Self.overlayVoteThreshold
        // 确认行 ±2 膨胀：pill 上下抗锯齿边缘行的票数偶有不足，由相邻确认行带掉。
        var bands = Set<Int>()
        for (key, voteCount) in overlayVotes where voteCount >= threshold {
            for spread in -2...2 { bands.insert(key + spread) }
        }
        for key in bands {
            let row = key >> 8, stripIndex = key & 0xFF
            guard stripIndex < strips else { continue }
            let localRow = row - origin                     // segment-local, top-based
            guard localRow >= 0, localRow < segmentHeight else { continue }
            let outRow = offset + localRow                  // output-local, top-based
            let firstSample = stripIndex * strip
            let x = anchor.sampleX[min(firstSample, anchor.sampleX.count - 1)]
            let endX = anchor.sampleX[min(firstSample + strip, anchor.sampleX.count) - 1]
            let stripWidth = max(1, endX - x)
            // 采样环带：条带上下 ±6/±12/±18/±24 行，中位数落在背景上的概率才够。
            var reds: [Int] = [], greens: [Int] = [], blues: [Int] = []
            for distance in [6, 12, 18, 24] {
                for ringRow in [outRow - distance, outRow + distance] where ringRow >= 0 && ringRow < total {
                    for px in x..<(x + stripWidth) {
                        let p = ringRow * bytesPerRow + px * 4   // BGRA，小端
                        blues.append(Int(base[p])); greens.append(Int(base[p + 1])); reds.append(Int(base[p + 2]))
                    }
                }
            }
            guard reds.count >= 8 else { continue }
            func median(_ values: inout [Int]) -> CGFloat {
                values.sort(); return CGFloat(values[values.count / 2]) / 255
            }
            // CGContext 原点在左下：输出第 r 行（自顶部）的底边 y = total - r。
            // 抹除矩形钳制在内容区内，不侵入上/下固定带。
            let bandTop = headerRows, bandBottom = total - footerRows
            let eraseTop = max(outRow - 3, bandTop), eraseBottom = min(outRow + 3, bandBottom)
            guard eraseBottom > eraseTop else { continue }
            let rect = CGRect(x: x - 3, y: total - eraseBottom, width: stripWidth + 6, height: eraseBottom - eraseTop)
            context.setFillColor(CGColor(srgbRed: median(&reds), green: median(&greens), blue: median(&blues), alpha: 1))
            context.fill(rect)
        }
    }

    // MARK: - Matching

    /// Rows identical at the same position in both frames, counted from each edge.
    static func staticBands(_ a: ScrollFrame, _ b: ScrollFrame, parameters: ScrollMatchParameters) -> (top: Int, bottom: Int) {
        let height = a.height
        var top = 0
        while top < height, rowsMatch(a, top, b, top, parameters) { top += 1 }
        var bottom = 0
        while bottom < height - top, rowsMatch(a, height - 1 - bottom, b, height - 1 - bottom, parameters) { bottom += 1 }
        return (top, bottom)
    }

    /// Finds how far content moved up (positive) or down (negative) inside `top..<end`.
    static func shift(anchor: ScrollFrame, frame: ScrollFrame, top: Int, end: Int, hint: Int?,
                      parameters: ScrollMatchParameters) -> Int? {
        let body = end - top
        let minimumOverlap = max(parameters.minimumOverlapRows, Int(Double(body) * parameters.minimumOverlapFraction))
        let limit = body - minimumOverlap
        guard limit > 0 else { return nil }
        let step = body > 900 ? 3 : body > 450 ? 2 : 1
        var costs: [(shift: Int, cost: Double)] = []
        costs.reserveCapacity(limit * 2)
        frame.mean.withUnsafeBufferPointer { frameMean in
            anchor.mean.withUnsafeBufferPointer { anchorMean in
                frame.detail.withUnsafeBufferPointer { frameDetail in
                    anchor.detail.withUnsafeBufferPointer { anchorDetail in
                        for shift in -limit...limit where shift != 0 {
                            let start = top + max(0, -shift), stop = end - max(0, shift)
                            var total: Int64 = 0, count = 0
                            var row = start
                            while row < stop {
                                let other = row + shift
                                total += Int64(abs(frameMean[row] - anchorMean[other]))
                                total += Int64(abs(frameDetail[row] - anchorDetail[other]))
                                count += 1; row += step
                            }
                            if count > 0 { costs.append((shift, Double(total) / Double(count))) }
                        }
                    }
                }
            }
        }
        costs.sort { $0.cost < $1.cost }
        var candidates: [Int] = []
        for entry in costs where !candidates.contains(where: { abs($0 - entry.shift) <= 3 }) {
            candidates.append(entry.shift)
            if candidates.count == 6 { break }
        }
        if let hint, abs(hint) <= limit {
            for value in [hint, hint - 2, hint + 2] where value != 0 && abs(value) <= limit && !candidates.contains(value) {
                candidates.append(value)
            }
        }
        // 精确候选附近 ±2 行复核，粗搜的抽样步长不会漏掉真正接缝。
        var refined: [Int] = []
        for candidate in candidates {
            for value in (candidate - step + 1)...(candidate + step - 1) where value != 0 && abs(value) <= limit && !refined.contains(value) {
                refined.append(value)
            }
        }

        struct Verified { let shift: Int; let ratio: Double; let evidence: Int }
        var verified: [Verified] = []
        for candidate in refined {
            guard let result = verify(anchor: anchor, frame: frame, shift: candidate, top: top, end: end, parameters: parameters) else { continue }
            if result.evidence >= 4, result.ratio <= parameters.maximumMismatchRatio {
                verified.append(Verified(shift: candidate, ratio: result.ratio, evidence: result.evidence))
            }
        }
        // 同一接缝的相邻位移只保留最佳一个，再判断是否存在真正不同的歧义位置。
        verified.sort { $0.ratio != $1.ratio ? $0.ratio < $1.ratio : $0.evidence > $1.evidence }
        var distinct: [Verified] = []
        for item in verified where !distinct.contains(where: { abs($0.shift - item.shift) <= 3 }) { distinct.append(item) }
        if let best = distinct.first {
            let rivals = distinct.dropFirst().filter { $0.ratio <= best.ratio + 0.04 }
            if rivals.isEmpty { return best.shift }
            let all = [best] + rivals
            if let hint { return all.min { abs($0.shift - hint) < abs($1.shift - hint) }?.shift }
            // 周期内容没有速度线索时，取最小位移：用户通常每次只滚动一小段。
            return all.min { abs($0.shift) < abs($1.shift) }?.shift
        }
        // 惯性滚动中的帧常在亚像素偏移上渲染，行被重采样后逐行一致率下降，严格验证会全部落选。
        // 只有精确位移线索背书、胜者唯一且重叠证据充分时，才允许更宽的失配率；周期内容仍然拒绝。
        if verified.isEmpty, let hint {
            var relaxed: [Verified] = []
            for candidate in refined {
                guard abs(candidate - hint) <= parameters.relaxedHintTolerance,
                      let result = verify(anchor: anchor, frame: frame, shift: candidate, top: top, end: end,
                                          parameters: parameters, ratioLimit: parameters.relaxedMismatchRatio)
                else { continue }
                let start = top + max(0, -candidate), stop = end - max(0, candidate)
                let minimumEvidence = max(parameters.relaxedMinimumEvidenceRows,
                                          Int(Double(stop - start) * parameters.relaxedMinimumEvidenceFraction))
                if result.evidence >= minimumEvidence {
                    relaxed.append(Verified(shift: candidate, ratio: result.ratio, evidence: result.evidence))
                }
            }
            relaxed.sort { $0.ratio != $1.ratio ? $0.ratio < $1.ratio : $0.evidence > $1.evidence }
            if let best = relaxed.first,
               !relaxed.dropFirst().contains(where: { $0.ratio <= best.ratio + parameters.relaxedRivalMargin }) {
                return best.shift
            }
        }
        // 大段空白没有图像证据；只有真实触控板位移可信时才沿用它，且重叠部分必须完全一致。
        if let hint, hint != 0, abs(hint) <= limit,
           let blank = verify(anchor: anchor, frame: frame, shift: hint, top: top, end: end, parameters: parameters),
           blank.evidence == 0, blank.mismatches == 0 {
            return hint
        }
        return nil
    }

    /// Mismatch ratio over rows that carry information at a given shift.
    static func verify(anchor: ScrollFrame, frame: ScrollFrame, shift: Int, top: Int, end: Int,
                       parameters: ScrollMatchParameters, ratioLimit: Double? = nil) -> (ratio: Double, evidence: Int, mismatches: Int)? {
        let start = top + max(0, -shift), stop = end - max(0, shift)
        guard stop > start else { return nil }
        let flat = Int32(frame.samples)
        let budget = Int(Double(stop - start) * (ratioLimit ?? parameters.maximumMismatchRatio)) + 4
        var mismatches = 0, matches = 0
        for row in start..<stop {
            let other = row + shift
            if rowsMatch(frame, row, anchor, other, parameters) {
                if frame.detail[row] >= flat || anchor.detail[other] >= flat { matches += 1 }
            } else {
                mismatches += 1
                if mismatches > budget { return (1, mismatches + matches, mismatches) }
            }
        }
        let evidence = mismatches + matches
        return (evidence == 0 ? 0 : Double(mismatches) / Double(evidence), evidence, mismatches)
    }

    /// Two sampled rows agree when only a few samples exceed the luminance tolerance.
    @inline(__always)
    static func rowsMatch(_ a: ScrollFrame, _ rowA: Int, _ b: ScrollFrame, _ rowB: Int, _ parameters: ScrollMatchParameters) -> Bool {
        let samples = a.samples
        let allowed = max(1, Int(Double(samples) * parameters.outlierFraction))
        let tolerance = parameters.tolerance
        // 平均亮度差超出所有样本都在容差内的上限时必然不同，避免逐样本比较。
        if Int(abs(a.mean[rowA] - b.mean[rowB])) > samples * Int(tolerance) + allowed * 255 { return false }
        return a.luma.withUnsafeBufferPointer { left in
            b.luma.withUnsafeBufferPointer { right in
                var outliers = 0
                var i = rowA * samples, j = rowB * samples
                let stop = i + samples
                while i < stop {
                    if abs(Int32(left[i]) - Int32(right[j])) > tolerance {
                        outliers += 1
                        if outliers > allowed { return false }
                    }
                    i += 1; j += 1
                }
                return true
            }
        }
    }

    /// Copies a row range so accepted slices never retain the source viewport's backing store.
    static func copyRows(_ image: CGImage, from first: Int, count: Int) throws -> CGImage {
        guard first >= 0, count > 0, first + count <= image.height,
              let crop = image.cropping(to: CGRect(x: 0, y: first, width: image.width, height: count)),
              let context = CGContext(data: nil, width: image.width, height: count, bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScrollCaptureError.image
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: count))
        guard let output = context.makeImage() else { throw ScrollCaptureError.image }
        return output
    }
}

/// Serial owner of stitching state and the bounded live thumbnail.
actor ScrollStitchWorker {
    private var stitcher: ScrollStitcher
    private var preview = ScrollPreviewAccumulator()
    private var previewSnapshot: ScrollPreviewSnapshot?

    init(pixelsPerPoint: CGFloat) { stitcher = ScrollStitcher(pixelsPerPoint: pixelsPerPoint) }

    /// Matches one viewport and returns scalar progress plus the refreshed preview.
    func add(_ image: CGImage, hint: Int?) throws -> ScrollStitchUpdate {
        try Task.checkCancellation()
        let frame = try ScrollFrame(image, pixelsPerPoint: stitcher.pixelsPerPoint)
        let isFirst = stitcher.frames == 0
        let previousCount = stitcher.segments.count
        let result = try stitcher.add(frame, hint: hint)
        if stitcher.didRewriteSegments {
            preview = ScrollPreviewAccumulator()
            var height = 0
            for segment in stitcher.segments {
                height += segment.height
                try? preview.append(segment, firstRow: 0, rows: segment.height, sourceHeight: height, frames: stitcher.frames)
            }
        } else if stitcher.segments.count > previousCount {
            var height = stitcher.contentHeight - stitcher.segments[previousCount...].reduce(0) { $0 + $1.height }
            for segment in stitcher.segments[previousCount...] {
                height += segment.height
                try? preview.append(segment, firstRow: 0, rows: segment.height, sourceHeight: height, frames: stitcher.frames)
            }
        }
        previewSnapshot = preview.snapshot
        return ScrollStitchUpdate(result: result, width: stitcher.width, height: stitcher.outputHeight,
                                  frames: stitcher.frames, preview: previewSnapshot,
                                  firstFrameUniform: isFirst && frame.isUniform)
    }

    /// Composes the final image; the worker keeps no pixels afterwards.
    func finish() throws -> CGImage {
        let image = try stitcher.makeImage()
        stitcher = ScrollStitcher(pixelsPerPoint: stitcher.pixelsPerPoint)
        preview = ScrollPreviewAccumulator(); previewSnapshot = nil
        return image
    }

    var frames: Int { stitcher.frames }
}

/// Scalar progress and the preview thumbnail returned after each viewport.
struct ScrollStitchUpdate: Sendable {
    let result: ScrollStitchResult
    let width: Int
    let height: Int
    let frames: Int
    let preview: ScrollPreviewSnapshot?
    var firstFrameUniform = false
}
