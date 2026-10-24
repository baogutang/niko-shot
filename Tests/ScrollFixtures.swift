// Generates deterministic synthetic documents and viewports for long-capture tests.
import CoreGraphics
import CoreText
import Foundation
@testable import NikoShot

actor ScrollImageFixture {
    /// A uniform image, e.g. for capture-geometry tests.
    func solid(width: Int, height: Int, gray: CGFloat = 0.5) throws -> CGImage {
        let context = try Self.context(width: width, height: height)
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    /// A long text document: headings, paragraphs, separators and repeated list rows, like a real page.
    func document(width: Int = 900, height: Int = 4_000, sparse: Bool = false) throws -> CGImage {
        try Self.document(width: width, height: height, sparse: sparse)
    }

    nonisolated static func document(width: Int, height: Int, sparse: Bool = false, badges: Bool = false) throws -> CGImage {
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(gray: 0.985, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if badges {
            // 内容锚定的重复徽标（比如列表里相同的头像）：像素级相同、随内容滚动，不能被当成浮层抹掉。
            var y = 20
            while y + 30 <= height {
                context.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.3, alpha: 1))
                context.fill(CGRect(x: 24, y: height - y - 30, width: 30, height: 30))
                y += 120
            }
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let small = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        var y = 40
        var index = 0
        while y < height - 60 {
            let heading = "Section \(index + 1) · niko-shot long capture \(index * 7_919 % 1_000)"
            draw(heading, font: font, gray: 0.12, x: 36, top: y, height: height, in: context)
            y += 44
            let lines = sparse ? 1 : 2 + index % 4
            for line in 0..<lines {
                let text = "Paragraph \(index)-\(line): " + String(repeating: ["native ", "scroll ", "stitch ", "capture "][(index + line) % 4], count: 3 + (index * 3 + line) % 6)
                draw(text, font: small, gray: 0.35, x: 36 + (line * 13 + index * 7) % 60, top: y, height: height, in: context)
                y += 28
            }
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 36, y: height - y - 10, width: width - 72, height: 2))
            y += sparse ? 260 : 36
            index += 1
        }
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    /// Full-width text lines every 28 rows: every overlay strip holds real content, so wrong erasures show.
    nonisolated static func denseDocument(width: Int, height: Int) throws -> CGImage {
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(gray: 0.985, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        let words = ["native ", "scroll ", "stitch ", "capture ", "window ", "pixels "]
        var y = 20, index = 0
        while y < height - 40 {
            var text = "Line \(index): "
            for word in 0..<40 { text += words[(index * 7 + word * 3) % words.count] }
            draw(text, font: font, gray: 0.2, x: 30 + (index * 13) % 40, top: y, height: height, in: context)
            y += 28; index += 1
        }
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    /// One viewport of `document` starting at `offset`, optionally wrapped in fixed chrome and overlays.
    nonisolated static func viewport(_ document: CGImage, offset: Int, height: Int, header: Int = 0, footer: Int = 0,
                                     scrollbarAt thumb: Int? = nil, noise: UInt8 = 0, seed: UInt64 = 1,
                                     floatingPill: Bool = false) throws -> CGImage {
        let body = height - header - footer
        guard offset >= 0, offset + body <= document.height,
              let slice = document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: body)) else {
            throw ScrollCaptureError.image
        }
        let width = document.width
        let context = try context(width: width, height: height)
        context.draw(slice, in: CGRect(x: 0, y: footer, width: width, height: body))
        if header > 0 {
            context.setFillColor(CGColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1))
            context.fill(CGRect(x: 0, y: height - header, width: width, height: header))
            draw("Toolbar · Back  Forward  Share", font: CTFontCreateWithName("Helvetica" as CFString, 16, nil),
                 gray: 0.95, x: 20, top: 12, height: height, in: context)
        }
        if footer > 0 {
            context.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: footer))
            draw("Type a message…", font: CTFontCreateWithName("Helvetica" as CFString, 15, nil),
                 gray: 0.5, x: 24, top: height - footer + 14, height: height, in: context)
        }
        if let thumb {
            context.setFillColor(CGColor(gray: 0.45, alpha: 0.8))
            context.fill(CGRect(x: width - 14, y: height - header - thumb - 90, width: 8, height: 90))
        }
        // 聊天应用的「回到底部」悬浮按钮：固定在视口底部中央，随每一帧一起被捕获。
        if floatingPill {
            let pillRect = CGRect(x: width / 2 - 32, y: 100, width: 64, height: 32)
            context.setFillColor(CGColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1))
            context.fillEllipse(in: pillRect)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: width / 2 - 6, y: 76, width: 12, height: 3))
        }
        guard var image = context.makeImage() else { throw ScrollCaptureError.image }
        if noise > 0 { image = try addNoise(image, amplitude: noise, seed: seed) }
        return image
    }

    /// Simulates a frame captured mid-momentum: the compositor renders at a fractional scroll
    /// offset, so every row is a vertical mix of its neighbours and text edges no longer agree
    /// crisply with the previous frame. Strict row equality fails; the true shift still ranks.
    nonisolated static func resampledViewport(_ document: CGImage, offset: Int, height: Int) throws -> CGImage {
        let base = try viewport(document, offset: offset, height: height, noise: 2, seed: 9)
        let bytes = try pixels(base)
        let width = base.width, rows = base.height, rowBytes = width * 4
        var mixed = bytes
        for row in 1..<(rows - 1) {
            let middle = row * rowBytes, stop = middle + rowBytes
            var index = middle
            while index < stop {
                // 3:1 vertical mix toward the next row; enough to break ±10 luminance
                // equality on text edges, like a real fractional-offset render.
                mixed[index] = UInt8(clamping: (Int(bytes[index]) * 3 + Int(bytes[index + rowBytes]) + 2) >> 2)
                index += 1
            }
        }
        let image = mixed.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: rows,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            return context.makeImage()
        }
        guard let image else { throw ScrollCaptureError.image }
        return image
    }

    nonisolated static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScrollCaptureError.image
        }
        return context
    }

    /// Reads 32-bit BGRA rows for exact comparisons.
    nonisolated static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try context(width: image.width, height: image.height)
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw ScrollCaptureError.image }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private nonisolated static func draw(_ text: String, font: CTFont, gray: CGFloat, x: Int, top: Int, height: Int, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)]
        context.textPosition = CGPoint(x: x, y: height - top - Int(CTFontGetSize(font)))
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    private nonisolated static func addNoise(_ image: CGImage, amplitude: UInt8, seed: UInt64) throws -> CGImage {
        var bytes = try pixels(image)
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let delta = Int(state >> 59) % (Int(amplitude) * 2 + 1) - Int(amplitude)
            for channel in 0..<3 { bytes[index + channel] = UInt8(clamping: Int(bytes[index + channel]) + delta) }
        }
        let context = try context(width: image.width, height: image.height)
        guard let data = context.data else { throw ScrollCaptureError.image }
        bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        guard let output = context.makeImage() else { throw ScrollCaptureError.image }
        return output
    }
}
