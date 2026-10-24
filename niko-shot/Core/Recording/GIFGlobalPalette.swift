// Preserves ImageIO's shared color indices while padding its optimized global table to 256 entries.
import Foundation

enum GIFGlobalPalette {
    /// A 6×6×6 cube (exact 0/51/…/255 levels) plus 40 grays between the cube grays, as interleaved RGB.
    /// A 3-3-2 cube has no neutral entries at all: gray 128 became (145,145,170) and 236 turned lavender.
    static let colors: [UInt8] = {
        var result: [UInt8] = []
        result.reserveCapacity(768)
        for red in 0..<6 { for green in 0..<6 { for blue in 0..<6 { result += [UInt8(red * 51), UInt8(green * 51), UInt8(blue * 51)] } } }
        for step in 0..<40 {
            let base: Double = Double(step / 8 * 51), offset: Double = Double(step % 8 + 1) * 51 / 9
            let value = UInt8((base + offset).rounded())
            result += [value, value, value]
        }
        return result
    }()

    /// Nearest cube level per channel; per-channel rounding is the exact nearest cube entry.
    private static let cubeLevel: [UInt8] = (0..<256).map { UInt8(($0 + 25) / 51) }
    /// Nearest neutral entry by r+g+b: the closest gray to any color is the one closest to its mean.
    private static let grayIndex: [UInt8] = {
        var grays: [Int] = []
        for entry in 0..<256 where colors[entry * 3] == colors[entry * 3 + 1] && colors[entry * 3] == colors[entry * 3 + 2] {
            grays.append(entry)
        }
        var table: [UInt8] = []
        table.reserveCapacity(766)
        for sum in 0...765 {
            var best = 0, bestError = Int.max
            for entry in grays {
                let value: Int = Int(colors[entry * 3])
                let error: Int = abs(value * 3 - sum)
                if error < bestError { best = entry; bestError = error }
            }
            table.append(UInt8(best))
        }
        return table
    }()

    /// Exact nearest palette entry (squared RGB distance); ties prefer the neutral entry so grays never tint.
    @inline(__always) static func index(red: Int, green: Int, blue: Int) -> UInt8 {
        let levelRed = Int(cubeLevel[red]), levelGreen = Int(cubeLevel[green]), levelBlue = Int(cubeLevel[blue])
        let cubeRed = red - levelRed * 51, cubeGreen = green - levelGreen * 51, cubeBlue = blue - levelBlue * 51
        let gray = Int(grayIndex[red + green + blue]), value = Int(colors[gray * 3])
        let grayRed: Int = red - value, grayGreen: Int = green - value, grayBlue: Int = blue - value
        let grayDistance: Int = grayRed * grayRed + grayGreen * grayGreen + grayBlue * grayBlue
        let cubeDistance: Int = cubeRed * cubeRed + cubeGreen * cubeGreen + cubeBlue * cubeBlue
        guard grayDistance > cubeDistance else { return UInt8(gray) }
        return UInt8(levelRed * 36 + levelGreen * 6 + levelBlue)
    }

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
