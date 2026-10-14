// 整行精确匹配：哈希用于定位，连续重叠和原始字节相等用于证明，不引入容差。
import CoreGraphics
import Foundation

/// 单个视口的紧密 BGRA 行；常见的 WindowServer BGRA 图像直接读取 provider。
struct RowHashFrame: Sendable {
    let image: CGImage
    let bytes: Data
    let hashes: [UInt64]
    /// 每行 64 个局部对比区域，颜色抖动不改变真正文字/图形的几何分布。
    let geometry: [UInt64]
    let width: Int
    var height: Int { hashes.count }
    var rowBytes: Int { width * 4 }

    init(_ image: CGImage) throws {
        guard image.width > 0, image.height > 0, image.width <= Int.max / 4,
              image.height <= Int.max / (image.width * 4) else { throw ScrollCaptureError.image }
        let width = image.width
        self.width = width
        let canonical: CGImage
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.bitmapInfo.contains(.byteOrder32Little), image.alphaInfo == .premultipliedFirst {
            canonical = image
        } else {
            // 只统一字节布局并保留原色域；比较前的颜色转换会放大 WindowServer 的量化差异。
            guard let canvas = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw ScrollCaptureError.image
            }
            canvas.interpolationQuality = .none
            canvas.setBlendMode(.copy)
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let result = canvas.makeImage() else { throw ScrollCaptureError.image }
            canonical = result
        }
        guard let provider = canonical.dataProvider, let data = provider.data,
              canonical.bytesPerRow >= width * 4, canonical.bytesPerRow <= Int.max / canonical.height,
              CFDataGetLength(data) >= canonical.bytesPerRow * canonical.height,
              let base = CFDataGetBytePtr(data) else { throw ScrollCaptureError.image }
        var packed = Data(count: width * 4 * canonical.height)
        var rows = [UInt64](); rows.reserveCapacity(canonical.height)
        var shape = [UInt64](); shape.reserveCapacity(canonical.height)
        try packed.withUnsafeMutableBytes { target in
            guard let destination = target.baseAddress else { throw ScrollCaptureError.image }
            for row in 0..<canonical.height {
                if row.isMultiple(of: 64) { try Task.checkCancellation() }
                let source = base.advanced(by: row * canonical.bytesPerRow)
                let output = destination.advanced(by: row * width * 4)
                output.copyMemory(from: source, byteCount: width * 4)
                rows.append(ExactRowHash.hash(UnsafeRawBufferPointer(start: output, count: width * 4)))
                shape.append(Self.geometry(of: UnsafeRawBufferPointer(start: output, count: width * 4), width: width))
            }
        }
        self.image = canonical; bytes = packed; hashes = rows; geometry = shape
    }

    /// 32 行中每个像素都同色才算纯色；整行相等不代表整行是纯色。
    func hasSolidTail(rows: Int = 32, ignoringBottom: Int = 0, maximumDifference: UInt8 = 0) -> Bool {
        let end = height - ignoringBottom
        guard end >= rows, rows > 0 else { return false }
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let first = (end - rows) * rowBytes
            var low = [UInt8](repeating: 255, count: 4), high = [UInt8](repeating: 0, count: 4)
            for offset in stride(from: first, to: end * rowBytes, by: 4) {
                for channel in 0..<4 {
                    low[channel] = min(low[channel], raw[offset + channel]); high[channel] = max(high[channel], raw[offset + channel])
                    if high[channel] - low[channel] > maximumDifference { return false }
                }
            }
            return true
        }
    }

    func rowsEqual(_ range: Range<Int>, to other: RowHashFrame, at start: Int) -> Bool {
        guard width == other.width, range.lowerBound >= 0, range.upperBound <= height,
              start >= 0, start + range.count <= other.height else { return false }
        return bytes.withUnsafeBytes { left in
            other.bytes.withUnsafeBytes { right in
                guard let a = left.baseAddress, let b = right.baseAddress else { return false }
                return memcmp(a.advanced(by: range.lowerBound * rowBytes),
                              b.advanced(by: start * rowBytes), range.count * rowBytes) == 0
            }
        }
    }

    func rowsAgree(_ range: Range<Int>, to other: RowHashFrame, at start: Int, maximumDifference: UInt8 = 3) -> Bool {
        guard width == other.width, range.lowerBound >= 0, range.upperBound <= height,
              start >= 0, start + range.count <= other.height else { return false }
        return bytes.withUnsafeBytes { a in
            other.bytes.withUnsafeBytes { b in
                guard let left = a.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let right = b.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return NikoPixelRowsEqual(left.advanced(by: range.lowerBound * rowBytes), right.advanced(by: start * rowBytes),
                                         range.count * rowBytes, maximumDifference)
            }
        }
    }

    private static func geometry(of row: UnsafeRawBufferPointer, width: Int) -> UInt64 {
        let cells = min(64, max(1, width / 4))
        var mask: UInt64 = 0
        for cell in 0..<cells {
            var low = 255, high = 0
            for x in (cell * width / cells)..<((cell + 1) * width / cells) {
                let p = x * 4
                let luma = (Int(row[p]) * 29 + Int(row[p + 1]) * 150 + Int(row[p + 2]) * 77) >> 8
                low = min(low, luma); high = max(high, luma)
            }
            if high - low >= 24 { mask |= UInt64(1) << cell }
        }
        return mask
    }
}

/// 固定 seed 的 xxHash64；完整行输入，64 位索引后仍用 memcmp 检查接受的重叠。
enum ExactRowHash {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261
    private static func rotate(_ x: UInt64, _ n: UInt64) -> UInt64 { (x << n) | (x >> (64 - n)) }
    private static func round(_ value: UInt64, _ input: UInt64) -> UInt64 { rotate(value &+ input &* p2, 31) &* p1 }
    private static func merge(_ hash: UInt64, _ value: UInt64) -> UInt64 { (hash ^ round(0, value)) &* p1 &+ p4 }

    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var i = 0, h: UInt64
        if bytes.count >= 32 {
            var a = p1 &+ p2, b = p2, c: UInt64 = 0, d = 0 &- p1
            while i <= bytes.count - 32 {
                a = round(a, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                b = round(b, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)))
                c = round(c, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)))
                d = round(d, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)))
                i += 32
            }
            h = rotate(a, 1) &+ rotate(b, 7) &+ rotate(c, 12) &+ rotate(d, 18)
            for v in [a, b, c, d] { h = merge(h, v) }
        } else { h = p5 }
        h &+= UInt64(bytes.count)
        while i + 8 <= bytes.count {
            h ^= round(0, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
            h = rotate(h, 27) &* p1 &+ p4; i += 8
        }
        if i + 4 <= bytes.count {
            h ^= UInt64(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* p1
            h = rotate(h, 23) &* p2 &+ p3; i += 4
        }
        while i < bytes.count {
            h ^= UInt64(bytes[i]) &* p5; h = rotate(h, 11) &* p1; i += 1
        }
        h ^= h >> 33; h &*= p2; h ^= h >> 29; h &*= p3; h ^= h >> 32
        return h
    }
}

struct RowHashSegment: Sendable {
    let image: CGImage
    let offset: Int
    var height: Int { image.height }
}

struct RowHashStitcher {
    private let options: ScrollCaptureOptions
    private let allowsRenderingVariance: Bool
    private(set) var rowHashes: [UInt64] = []
    private(set) var segments: [RowHashSegment] = []
    private(set) var previous: RowHashFrame?
    private(set) var lastObserved: RowHashFrame?
    private(set) var width = 0, height = 0, frames = 0
    private(set) var ignoredTop = 0, ignoredBottom = 0
    private(set) var isBacktracking = false
    private(set) var revisedFirstFrame = false
    private var bottomImage: CGImage?
    private var footerIncluded = false
    var viewportHeight: Int { (previous?.height ?? 0) - ignoredTop - ignoredBottom }
    var residentBufferBytes: Int {
        let frames = (previous?.bytes.count ?? 0) + (lastObserved?.bytes.count ?? 0)
        let slices = segments.reduce(0) { $0 + $1.image.bytesPerRow * $1.height }
        let footer = bottomImage.map { $0.bytesPerRow * $0.height } ?? 0
        return rowHashes.count * 8 + frames + slices + footer
    }

    init(options: ScrollCaptureOptions = ScrollCaptureOptions(), allowsRenderingVariance: Bool = false) {
        self.options = options; self.allowsRenderingVariance = allowsRenderingVariance
        ignoredTop = options.ignoredTop; ignoredBottom = options.ignoredBottom
    }

    mutating func append(_ image: CGImage) throws -> ScrollAppendResult {
        try append(RowHashFrame(image))
    }

    mutating func append(_ next: RowHashFrame) throws -> ScrollAppendResult {
        try Task.checkCancellation()
        revisedFirstFrame = false; isBacktracking = false
        guard !footerIncluded else { throw ScrollCaptureError.closed }
        if let previous, (previous.width != next.width || previous.height != next.height) { throw ScrollTargetError.windowResized }
        guard next.height > ignoredTop + ignoredBottom else { throw ScrollCaptureError.invalidBands }
        lastObserved = next
        guard let previous else {
            width = next.width
            rowHashes = Array(next.hashes[ignoredTop..<(next.height - ignoredBottom)])
            try addSegment(next.image, firstRow: ignoredTop, rows: rowHashes.count)
            self.previous = next; frames = 1
            return .appended(height: height, frames: frames)
        }
        if previous.hashes == next.hashes, next.rowsEqual(0..<next.height, to: previous, at: 0) { return .duplicate }
        if frames > 1 {
            let body = ignoredTop..<(next.height - ignoredBottom)
            if previous.hashes[body].elementsEqual(next.hashes[body]), next.rowsEqual(body, to: previous, at: ignoredTop) {
                return .duplicate
            }
        }

        // 固定条只在首个真正移动的视口建立；同一屏重复采样不能证明固定 chrome。
        if frames == 1, options.ignoredTop == 0, options.ignoredBottom == 0 {
            var top = 0, bottom = 0
            while top < next.height - 1, previous.hashes[top] == next.hashes[top] { top += 1 }
            while bottom < next.height - top - 1,
                  previous.hashes[next.height - bottom - 1] == next.hashes[next.height - bottom - 1] { bottom += 1 }
            // 优先不裁切；仅连续平移的正文能证明需要忽略固定条。
            for bands in [(0, 0), (top, 0), (0, bottom), (top, bottom)] {
                guard next.height - bands.0 - bands.1 >= min(32, next.height),
                      let overlap = forwardOverlap(previous: previous, current: next, top: bands.0, bottom: bands.1) else { continue }
                if bands.0 + bands.1 > 0 {
                    ignoredTop = bands.0; ignoredBottom = bands.1
                    rowHashes = Array(previous.hashes[ignoredTop..<(previous.height - ignoredBottom)])
                    // 自动检测的顶部保留一次，底部挪到最终视口，只出现一次。
                    segments.removeAll(); height = 0
                    try addSegment(previous.image, firstRow: 0, rows: previous.height - ignoredBottom)
                    revisedFirstFrame = true
                }
                return try accept(next, overlap: overlap)
            }
        } else if let overlap = forwardOverlap(previous: previous, current: next, top: ignoredTop, bottom: ignoredBottom) {
            return try accept(next, overlap: overlap)
        }

        // 向上回滚只浏览已截内容；不移动已经接受的末端，也不参与到底计数。
        let body = Array(next.hashes[ignoredTop..<(next.height - ignoredBottom)])
        if Self.contains(rowHashes, pattern: body) || Self.reverseOverlap(previous: previous, current: next, top: ignoredTop, bottom: ignoredBottom) ||
            (allowsRenderingVariance && Self.geometricOverlap(previous: next, current: previous, top: ignoredTop, bottom: ignoredBottom) != nil) {
            isBacktracking = true; return .duplicate
        }
        return .skipped
    }

    private mutating func accept(_ next: RowHashFrame, overlap: Int) throws -> ScrollAppendResult {
        let end = next.height - ignoredBottom, start = ignoredTop + overlap
        guard start < end else { return .duplicate }
        try addSegment(next.image, firstRow: start, rows: end - start)
        rowHashes.append(contentsOf: next.hashes[start..<end])
        previous = next; frames += 1
        if ignoredBottom > 0, options.ignoredBottom == 0 {
            bottomImage = try Self.copySlice(next.image, firstRow: end, rows: ignoredBottom)
        }
        return .appended(height: height, frames: frames)
    }

    /// 按候选末行自上而下定位，随后校验整段重叠；重复背景或周期图案有歧义时跳过。
    private func forwardOverlap(previous: RowHashFrame, current: RowHashFrame, top: Int, bottom: Int) -> Int? {
        if let exact = Self.exactOverlap(previous: previous, current: current, top: top, bottom: bottom) { return exact }
        guard allowsRenderingVariance else { return nil }
        return Self.geometricOverlap(previous: previous, current: current, top: top, bottom: bottom)
    }

    private static func exactOverlap(previous: RowHashFrame, current: RowHashFrame, top: Int, bottom: Int) -> Int? {
        let end = previous.height - bottom, length = end - top
        guard length > 1 else { return nil }
        let last = previous.hashes[end - 1], minimum = min(32, length - 1)
        var accepted: Int?
        for j in (top + minimum - 1)..<(end - 1) where current.hashes[j] == last {
            let overlap = j - top + 1, start = end - overlap
            guard previous.hashes[start..<end].elementsEqual(current.hashes[top...j]),
                  current.rowsEqual(top..<(top + overlap), to: previous, at: start),
                  previous.hashes[start..<end].contains(where: { $0 != last }) else { continue }
            if accepted != nil { return nil }
            accepted = overlap
        }
        return accepted
    }

    /// 哈希未命中时由文字/图形位置给出整数位移，再检查整段原始重叠的每个通道。
    /// 限定到 3/255 的渲染差异，不使用平均分，也不允许局部高分掩盖错位。
    private static func geometricOverlap(previous: RowHashFrame, current: RowHashFrame, top: Int, bottom: Int) -> Int? {
        let end = previous.height - bottom, length = end - top, minimum = min(32, length - 1)
        guard length > 1 else { return nil }
        var anchors: [Int] = [], last = end
        for row in stride(from: end - 1, through: top, by: -1) where previous.geometry[row] != 0 {
            if last - row >= 8 { anchors.append(row); last = row }
            if anchors.count == 8 { break }
        }
        guard !anchors.isEmpty else { return nil }
        var offsets = Set<Int>()
        for anchor in anchors {
            for row in top..<end where current.geometry[row] == previous.geometry[anchor] {
                let shift = anchor - row
                if shift > 0, length - shift >= minimum { offsets.insert(shift) }
            }
        }
        var accepted: Int?
        for shift in offsets.sorted() {
            if Task.isCancelled { return nil }
            let overlap = length - shift
            guard current.rowsAgree(top..<(top + overlap), to: previous, at: top + shift) else { continue }
            // 周期背景依然不能证明唯一位移；宁可跳过，也不靠速度猜接缝。
            if accepted != nil { return nil }
            accepted = overlap
        }
        return accepted
    }

    private static func reverseOverlap(previous: RowHashFrame, current: RowHashFrame, top: Int, bottom: Int) -> Bool {
        let end = previous.height - bottom, length = end - top
        guard length > 1 else { return false }
        let minimum = min(32, length - 1), first = previous.hashes[top]
        for start in (top + 1)...(end - minimum) where current.hashes[start] == first {
            let count = end - start
            if previous.hashes[top..<(top + count)].elementsEqual(current.hashes[start..<end]),
               previous.hashes[top..<(top + count)].contains(where: { $0 != first }),
               current.rowsEqual(start..<end, to: previous, at: top) { return true }
        }
        return false
    }

    private static func contains(_ rows: [UInt64], pattern: [UInt64]) -> Bool {
        guard !pattern.isEmpty, rows.count >= pattern.count,
              pattern.contains(where: { $0 != pattern[0] }) else { return false }
        // KMP 避免长聊天记录和重复空白背景把中间位置查找变成平方复杂度。
        var prefix = [Int](repeating: 0, count: pattern.count), k = 0
        for i in 1..<pattern.count {
            while k > 0, pattern[k] != pattern[i] { k = prefix[k - 1] }
            if pattern[k] == pattern[i] { k += 1 }; prefix[i] = k
        }
        k = 0
        for row in rows {
            while k > 0, pattern[k] != row { k = prefix[k - 1] }
            if pattern[k] == row { k += 1 }
            if k == pattern.count { return true }
        }
        return false
    }

    mutating func includeFooter() throws {
        guard !footerIncluded else { return }
        if let bottomImage { try addSegment(bottomImage, firstRow: 0, rows: bottomImage.height) }
        footerIncluded = true
    }

    private mutating func addSegment(_ image: CGImage, firstRow: Int, rows: Int) throws {
        let (total, overflow) = height.addingReportingOverflow(rows)
        guard !overflow, total <= Int(Int32.max) else { throw ScrollCaptureError.dimensionOverflow }
        let slice = try Self.copySlice(image, firstRow: firstRow, rows: rows)
        segments.append(RowHashSegment(image: slice, offset: height)); height = total
    }

    /// CGImage 的 crop 可能继续持有整个视口 provider；复制的仅是新行，避免每 5px 保留一张大图。
    static func copySlice(_ image: CGImage, firstRow: Int, rows: Int) throws -> CGImage {
        guard firstRow >= 0, rows > 0, firstRow <= image.height - rows,
              let crop = image.cropping(to: CGRect(x: 0, y: firstRow, width: image.width, height: rows)),
              let canvas = CGContext(data: nil, width: image.width, height: rows, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw ScrollCaptureError.image }
        canvas.interpolationQuality = .none; canvas.setBlendMode(.copy)
        canvas.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: rows))
        guard let output = canvas.makeImage() else { throw ScrollCaptureError.image }
        return output
    }

    /// 只绘制已经接受的裁片，未匹配的原始候选不会出现在最终画布。
    func composedImage() throws -> CGImage {
        guard frames > 0, height > 0, height <= 32_767,
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: previous?.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw ScrollCaptureError.image }
        canvas.interpolationQuality = .none; canvas.setBlendMode(.copy)
        for segment in segments {
            try Task.checkCancellation()
            canvas.draw(segment.image, in: CGRect(x: 0, y: height - segment.offset - segment.height, width: width, height: segment.height))
        }
        guard let image = canvas.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    /// 分块 writer 提交后释放裁片，累计哈希与末端视口继续用于匹配。
    mutating func releaseSegments() { segments.removeAll() }
}

struct ScrollBottomDetector {
    static let requiredDuplicates = 8
    private(set) var consecutiveDuplicates = 0
    private(set) var consecutiveUnchangedEvents = 0
    private var observed: [UInt64]?

    mutating func observe(_ frame: RowHashFrame, result: ScrollAppendResult, isScrollEvent: Bool,
                          backtracking: Bool, ignoredBottom: Int) -> Bool {
        defer { observed = frame.hashes }
        if isScrollEvent, !backtracking, result == .duplicate, observed == frame.hashes { consecutiveUnchangedEvents += 1 }
        else { consecutiveUnchangedEvents = 0 }
        guard isScrollEvent, !backtracking, result == .duplicate, observed == frame.hashes,
              !frame.hasSolidTail(ignoringBottom: ignoredBottom, maximumDifference: 3) else {
            consecutiveDuplicates = 0; return false
        }
        consecutiveDuplicates += 1
        return consecutiveDuplicates >= Self.requiredDuplicates
    }
}
