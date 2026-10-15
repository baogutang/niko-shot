// Draws annotations in canvas points with Core Graphics; the live canvas and export share every path.
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import os

/// Full-image pixellate/blur results, computed once per strength and reused by live drawing and export.
final class AnnotationEffects: Sendable {
    let base: CGImage
    let canvasSize: CGSize
    private let cache = OSAllocatedUnfairLock<[String: CGImage]>(initialState: [:])
    private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    init(base: CGImage, canvasSize: CGSize) { self.base = base; self.canvasSize = canvasSize }

    /// Pixels per canvas point for the base image.
    var pixelScale: CGFloat { CGFloat(base.width) / max(1, canvasSize.width) }

    func image(for item: AnnotationItem) -> CGImage? {
        let blur = item.tool == .blur
        let strength = blur ? max(4, item.width * 2.2) : max(5, item.width * 2.6)
        let pixels = (strength * pixelScale).rounded()
        let key = "\(blur ? "b" : "m")\(Int(pixels))"
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let source = CIImage(cgImage: base).clampedToExtent()
        let processed = blur
            ? source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: pixels])
            : source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: pixels,
                kCIInputCenterKey: CIVector(x: 0, y: 0)])
        let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        guard let output = Self.context.createCGImage(processed.cropped(to: extent), from: extent) else { return nil }
        cache.withLock { $0[key] = output }
        return output
    }
}

enum AnnotationRenderer {
    /// Produces the exported pixels from the immutable base and document; runs on a worker task.
    static func render(base: CGImage, document: AnnotationDocument, scale: CGFloat, effects: AnnotationEffects? = nil) throws -> CGImage {
        guard scale.isFinite, scale > 0 else { throw AppError.imageCreation }
        let width = Int((document.canvasSize.width * scale).rounded())
        let height = Int((document.canvasSize.height * scale).rounded())
        let context = try ImageUtilities.context(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !document.commands.isEmpty else {
            guard let image = context.makeImage() else { throw AppError.imageCreation }
            return image
        }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        let shared = effects ?? AnnotationEffects(base: base, canvasSize: document.canvasSize)
        for item in document.commands {
            try Task.checkCancellation()
            // Filters and magnifiers sample the composed document, including earlier marks.
            // This bitmap renderer runs off the main thread in the live canvas and export paths.
            let source: AnnotationEffects
            if item.tool.isEffect || item.tool == .magnifier, let composed = context.makeImage() {
                source = AnnotationEffects(base: composed, canvasSize: document.canvasSize)
            } else { source = shared }
            draw(item, in: context, effects: source)
        }
        guard let image = context.makeImage() else { throw AppError.imageCreation }
        return image
    }

    /// Draws one item into a context whose user space is canvas points with a top-left origin.
    static func draw(_ item: AnnotationItem, in context: CGContext, effects: AnnotationEffects) {
        context.saveGState(); defer { context.restoreGState() }
        let color = item.color.cgColor
        context.setStrokeColor(color); context.setFillColor(color)
        context.setLineWidth(item.width); context.setLineCap(.round); context.setLineJoin(.round)
        let device = max(0.5, abs(context.ctm.d))
        func softShadow(_ alpha: CGFloat = 0.28) {
            context.setShadow(offset: CGSize(width: 0, height: -1 * device), blur: 3 * device,
                              color: CGColor(gray: 0, alpha: alpha))
        }
        switch item.tool {
        case .rectangle:
            let rect = item.rect.standardized
            let radius = min(rect.width, rect.height) > 16 ? min(6, 2 + item.width * 0.6) : 0
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            softShadow()
            context.addPath(path)
            item.filled ? context.fillPath() : context.strokePath()
        case .ellipse:
            softShadow()
            context.addEllipse(in: item.rect.standardized)
            item.filled ? context.fillPath() : context.strokePath()
        case .line:
            guard let first = item.points.first, let last = item.points.last else { return }
            softShadow()
            context.move(to: first); context.addLine(to: last); context.strokePath()
        case .arrow:
            guard let first = item.points.first, let last = item.points.last, let path = arrowPath(from: first, to: last, width: item.width) else { return }
            softShadow()
            context.addPath(path); context.fillPath()
            context.addPath(path); context.setLineWidth(1); context.strokePath()
        case .pen:
            softShadow(0.2)
            context.addPath(smoothPath(item.points)); context.strokePath()
        case .highlight:
            context.setAlpha(0.38)
            context.setBlendMode(.multiply)
            let rect = item.rect.standardized
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(3, rect.height / 4), cornerHeight: min(3, rect.height / 4), transform: nil))
            context.fillPath()
        case .mosaic, .blur:
            guard let image = effects.image(for: item) else { return }
            let rect = item.rect.standardized
            if item.points.count > 2 {
                context.addPath(smoothPath(item.points)); context.setLineWidth(max(14, item.width * 5))
                context.replacePathWithStrokedPath(); context.clip()
            } else {
                context.clip(to: rect)
            }
            drawImage(image, in: CGRect(origin: .zero, size: effects.canvasSize), context: context)
        case .text, .note:
            let rect = item.rect.standardized
            guard !rect.isEmpty, !item.text.isEmpty else { return }
            if item.tool == .note {
                context.saveGState()
                softShadow(0.25)
                context.setFillColor(noteFill(for: item.color))
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.fillPath()
                context.restoreGState()
                drawText(item.text, font: item.font, color: noteText(for: item.color),
                         rect: rect.insetBy(dx: textInset(for: item).width, dy: textInset(for: item).height), context: context)
            } else {
                softShadow(0.35)
                drawText(item.text, font: item.font, color: color, rect: rect, context: context)
            }
        case .step:
            let diameter = AnnotationItem.stepDiameter(for: item.width)
            let circle = CGRect(x: item.rect.midX - diameter / 2, y: item.rect.midY - diameter / 2, width: diameter, height: diameter)
            context.saveGState()
            softShadow(0.3)
            context.fillEllipse(in: circle)
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); context.setLineWidth(max(1.2, diameter * 0.06))
            context.strokeEllipse(in: circle.insetBy(dx: 0.6, dy: 0.6))
            let textColor = item.color.luminance > 0.72 ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1)
            drawCentered(String(item.number), size: diameter * 0.52, color: textColor, in: circle, context: context)
        case .magnifier:
            let rect = item.rect.standardized
            guard rect.width > 4, rect.height > 4 else { return }
            let scale = effects.pixelScale
            let zoom: CGFloat = 2
            let sample = CGRect(x: (rect.midX - rect.width / (2 * zoom)) * scale, y: (rect.midY - rect.height / (2 * zoom)) * scale,
                                width: rect.width / zoom * scale, height: rect.height / zoom * scale)
                .intersection(CGRect(x: 0, y: 0, width: effects.base.width, height: effects.base.height))
            context.saveGState()
            softShadow(0.35)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: rect)
            context.restoreGState()
            context.saveGState()
            context.addEllipse(in: rect); context.clip()
            context.interpolationQuality = .none
            if !sample.isNull, let crop = effects.base.cropping(to: sample) { drawImage(crop, in: rect, context: context) }
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(3)
            context.strokeEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
            context.setStrokeColor(color); context.setLineWidth(max(1.5, item.width * 0.5))
            context.strokeEllipse(in: rect)
        }
    }

    // MARK: - Geometry

    /// A tapered shaft with a filled head, like a hand-drawn callout.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return nil }
        let ux = dx / length, uy = dy / length, nx = -uy, ny = ux
        let headLength = min(length * 0.65, max(12, width * 4.4))
        let headHalf = max(7, width * 2.7)
        let neckHalf = max(1.6, width * 0.7)
        let tailHalf = max(0.6, width * 0.22)
        let neck = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.x + nx * tailHalf, y: start.y + ny * tailHalf))
        path.addLine(to: CGPoint(x: neck.x + nx * neckHalf, y: neck.y + ny * neckHalf))
        path.addLine(to: CGPoint(x: neck.x + nx * headHalf, y: neck.y + ny * headHalf))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: neck.x - nx * headHalf, y: neck.y - ny * headHalf))
        path.addLine(to: CGPoint(x: neck.x - nx * neckHalf, y: neck.y - ny * neckHalf))
        path.addLine(to: CGPoint(x: start.x - nx * tailHalf, y: start.y - ny * tailHalf))
        path.closeSubpath()
        return path
    }

    /// Quadratic smoothing through midpoints removes the jagged look of raw mouse samples.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last == first ? CGPoint(x: first.x + 0.01, y: first.y) : last) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index], next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2), control: current)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    // MARK: - Text

    static func font(_ snapshot: FontSnapshot) -> CTFont {
        let font = CTFontCreateWithName(snapshot.postScriptName as CFString, snapshot.pointSize, nil)
        // CoreText substitutes a fallback when the name is missing; keep a bold system face for legibility.
        if (CTFontCopyPostScriptName(font) as String) != snapshot.postScriptName {
            return NSFont.systemFont(ofSize: snapshot.pointSize, weight: .semibold) as CTFont
        }
        return font
    }

    static func textInset(for item: AnnotationItem) -> CGSize {
        item.tool == .note ? CGSize(width: max(6, item.font.pointSize * 0.45), height: max(4, item.font.pointSize * 0.3)) : .zero
    }

    /// Measures wrapped text in points for a maximum width.
    static func measure(_ text: String, font snapshot: FontSnapshot, maximumWidth: CGFloat) -> CGSize {
        let string = attributed(text.isEmpty ? " " : text, font: font(snapshot), color: CGColor(gray: 0, alpha: 1))
        let setter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(20, maximumWidth), height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }

    private static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
    }

    private static func drawText(_ value: String, font snapshot: FontSnapshot, color: CGColor, rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let string = attributed(value, font: font(snapshot), color: color)
        let setter = CTFramesetterCreateWithAttributedString(string)
        // Allow a little vertical slack so the last line is never clipped by rounding.
        let box = CGRect(x: 0, y: 0, width: rect.width + 1, height: rect.height + snapshot.pointSize)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + box.height); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawCentered(_ value: String, size: CGFloat, color: CGColor, in rect: CGRect, context: CGContext) {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
        let line = CTLineCreateWithAttributedString(attributed(value, font: font, color: color))
        let bounds = CTLineGetImageBounds(line, context)
        context.saveGState()
        context.translateBy(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY + bounds.height / 2 + bounds.minY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func noteFill(for color: AnnotationColor) -> CGColor {
        color.luminance < 0.25 ? CGColor(gray: 0.12, alpha: 0.92) :
            CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.95)
    }

    private static func noteText(for color: AnnotationColor) -> CGColor {
        color.luminance > 0.6 ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }

    /// Draws an image upright inside a top-left-origin context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
