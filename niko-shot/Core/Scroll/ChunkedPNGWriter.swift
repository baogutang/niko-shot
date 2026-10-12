// Spools straight-alpha RGBA in 5000-row chunks and streams a single standards-compliant zlib PNG.
import CoreGraphics
import Foundation
import zlib

struct ScrollPixelRows {
    let context: CGContext
    let width: Int, height: Int
    var byteCount: Int { context.bytesPerRow * height }
    init(_ image: CGImage) throws {
        guard image.width > 0, image.height > 0, image.width <= Int.max / 4,
              image.height <= Int.max / (image.width * 4),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScrollCaptureError.image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.context = context; width = image.width; height = image.height
    }
    func row(at index: Int) throws -> Data {
        guard index >= 0, index < height, let base = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ScrollCaptureError.image }
        let source = base.advanced(by: index * context.bytesPerRow)
        var output = Data(count: width * 4)
        output.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for pixel in 0..<width {
                let offset = pixel * 4, alpha = Int(source[offset + 3])
                bytes[offset + 3] = UInt8(alpha)
                for channel in 0..<3 {
                    bytes[offset + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(source[offset + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        return output
    }
}

/// Disk-backed row writer. Its owning scroll actor is the only caller of all methods.
final class ChunkedPNGWriter {
    struct Chunk { let url: URL; var height: Int }
    let directory: URL
    let width: Int
    private(set) var height = 0
    private(set) var chunks: [Chunk] = []
    private var current: FileHandle?
    private let checkCancellation: () throws -> Void
    private(set) var peakBufferBytes = 0
    var openFiles: Int { current == nil ? 0 : 1 }
    var residentBufferBytes: Int { width * 8 + 65_536 }

    init(directory: URL, width: Int, checkCancellation: @escaping () throws -> Void) throws {
        guard width > 0, width <= Int(Int32.max), width <= Int(UInt32.max) / 4 else { throw ScrollCaptureError.dimensionOverflow }
        self.directory = directory; self.width = width; self.checkCancellation = checkCancellation
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit {
        try? current?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Appends a bounded source frame; only one frame's bitmap is present while rows are being spooled.
    func append(image: CGImage, firstRow: Int, numberOfRows: Int) throws {
        guard image.width == width, firstRow >= 0, numberOfRows > 0,
              firstRow <= image.height - numberOfRows else { throw ScrollCaptureError.invalidOverlap }
        let (newHeight, overflow) = height.addingReportingOverflow(numberOfRows)
        guard !overflow, newHeight <= Int(Int32.max) else { throw ScrollCaptureError.dimensionOverflow }
        try checkCancellation()
        let pixels = try ScrollPixelRows(image)
        peakBufferBytes = max(peakBufferBytes, pixels.byteCount + residentBufferBytes)
        for row in firstRow..<(firstRow + numberOfRows) {
            if row.isMultiple(of: 32) { try checkCancellation() }
            // FileHandle bridges through Foundation; promptly drain each temporary row's objects.
            try autoreleasepool {
                if current == nil || chunks.last?.height == 5_000 { try beginChunk() }
                guard let current else { throw ScrollCaptureError.disk("长图分块已经关闭。") }
                try current.write(contentsOf: pixels.row(at: row))
                chunks[chunks.count - 1].height += 1; height += 1
            }
        }
    }

    /// Encodes rows sequentially across chunk boundaries, never assembling the final long bitmap.
    func writePNG(to destination: URL) throws {
        guard height > 0 else { throw ScrollCaptureError.noFrames }
        try current?.close(); current = nil
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ScrollCaptureError.disk("无法创建 PNG 文件。") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var header = Data(); header.append(Self.bigEndian(UInt32(width))); header.append(Self.bigEndian(UInt32(height)))
        header.append(contentsOf: [8, 6, 0, 0, 0])
        try Self.chunk("IHDR", payload: header, output: output)
        // Row rasterization uses sRGB; label the output so wide-gamut displays interpret colors correctly.
        try Self.chunk("sRGB", payload: Data([0]), output: output)
        var stream = z_stream()
        let initialized = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw ScrollCaptureError.disk("PNG 压缩初始化失败 (\(initialized))。") }
        defer { deflateEnd(&stream) }
        var compressed = [UInt8](repeating: 0, count: 65_536)
        let rowBytes = width * 4
        peakBufferBytes = max(peakBufferBytes, rowBytes * 2 + compressed.count + 262_144)
        for chunk in chunks {
            try checkCancellation()
            let input = try FileHandle(forReadingFrom: chunk.url)
            defer { try? input.close() }
            for _ in 0..<chunk.height {
                try checkCancellation()
                try autoreleasepool {
                    var row = Data([0]) // Filter 0 keeps alpha and orientation exact, including transparent pixels.
                    row.append(try Self.readExactly(rowBytes, from: input))
                    try row.withUnsafeBytes { bytes in
                        guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw ScrollCaptureError.image }
                        stream.next_in = UnsafeMutablePointer(mutating: pointer); stream.avail_in = uInt(row.count)
                        repeat {
                            try checkCancellation()
                            try compressed.withUnsafeMutableBufferPointer { buffer in
                                guard let base = buffer.baseAddress else { throw ScrollCaptureError.image }
                                stream.next_out = base; stream.avail_out = uInt(buffer.count)
                                let status = deflate(&stream, Z_NO_FLUSH)
                                guard status == Z_OK || (status == Z_BUF_ERROR && stream.avail_in == 0) else {
                                    throw ScrollCaptureError.disk("PNG 压缩失败 (\(status))。")
                                }
                                let count = buffer.count - Int(stream.avail_out)
                                if count > 0 { try Self.chunk("IDAT", payload: Data(bytes: base, count: count), output: output) }
                            }
                        } while stream.avail_in > 0 || stream.avail_out == 0
                    }
                }
            }
        }
        stream.next_in = nil; stream.avail_in = 0
        var ended = false
        while !ended {
            try checkCancellation()
            try compressed.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { throw ScrollCaptureError.image }
                stream.next_out = base; stream.avail_out = uInt(buffer.count)
                let status = deflate(&stream, Z_FINISH)
                guard status == Z_OK || status == Z_STREAM_END else { throw ScrollCaptureError.disk("PNG 压缩结束失败 (\(status))。") }
                let count = buffer.count - Int(stream.avail_out)
                if count > 0 { try Self.chunk("IDAT", payload: Data(bytes: base, count: count), output: output) }
                ended = status == Z_STREAM_END
            }
        }
        try Self.chunk("IEND", payload: Data(), output: output)
        try output.synchronize(); try output.close()
    }

    /// Closes descriptors and removes only this writer's uniquely owned staging directory.
    func cleanup() {
        try? current?.close(); current = nil
        try? FileManager.default.removeItem(at: directory); chunks.removeAll()
    }

    private func beginChunk() throws {
        try current?.close(); current = nil
        let url = directory.appendingPathComponent(String(format: "chunk-%05d.rgba", chunks.count))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ScrollCaptureError.disk("无法创建长图分块。") }
        current = try FileHandle(forWritingTo: url); chunks.append(Chunk(url: url, height: 0))
    }
    private static func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { throw ScrollCaptureError.disk("长图分块不完整。") }
            data.append(part)
        }
        return data
    }
    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private static func chunk(_ name: String, payload: Data, output: FileHandle) throws {
        let type = Data(name.utf8)
        guard type.count == 4, payload.count <= Int(UInt32.max) else { throw ScrollCaptureError.dimensionOverflow }
        var checksum = type.withUnsafeBytes { bytes -> uLong in
            crc32(0, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(type.count))
        }
        if !payload.isEmpty {
            checksum = payload.withUnsafeBytes { bytes in
                crc32(checksum, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(payload.count))
            }
        }
        try output.write(contentsOf: bigEndian(UInt32(payload.count))); try output.write(contentsOf: type)
        try output.write(contentsOf: payload); try output.write(contentsOf: bigEndian(UInt32(checksum)))
    }
}
