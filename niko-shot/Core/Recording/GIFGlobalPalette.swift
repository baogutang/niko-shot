// Preserves ImageIO's shared color indices while padding its optimized global table to 256 entries.
import Foundation

enum GIFGlobalPalette {
    /// ImageIO shrinks even an explicit 256-color indexed space; extend the table without changing any pixel index.
    static func ensure256Colors(at source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard var header = try input.read(upToCount: 13), header.count == 13,
              String(decoding: header.prefix(3), as: UTF8.self) == "GIF", header[10] & 0x80 != 0 else {
            throw GifExportError.destination
        }
        let count = 1 << (Int(header[10] & 0x07) + 1)
        guard count < 256 else { return }
        guard var palette = try input.read(upToCount: count * 3), palette.count == count * 3 else {
            throw GifExportError.destination
        }
        palette.append(Data(repeating: 0, count: (256 - count) * 3))
        header[10] |= 0x77
        let stage = source.deletingLastPathComponent().appendingPathComponent(".niko-shot-palette-\(UUID().uuidString).gif")
        guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw GifExportError.destination }
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = try FileHandle(forWritingTo: stage)
        defer { try? output.close() }
        try output.write(contentsOf: header); try output.write(contentsOf: palette)
        while let data = try input.read(upToCount: 131_072), !data.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: data)
        }
        try output.close(); try input.close()
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(source, withItemAt: stage)
    }
}
