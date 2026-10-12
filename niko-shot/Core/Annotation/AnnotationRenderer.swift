// Re-renders every tool at arbitrary scale with Core Graphics, Core Text and Core Image.
import CoreGraphics
import CoreImage
import CoreText

enum AnnotationRenderer {
    /// Produces a pixel image from the immutable base and document; execute on a worker task.
    static func render(base: CGImage, document: AnnotationDocument, scale: CGFloat) throws -> CGImage {
        guard scale.isFinite, scale > 0 else { throw AppError.imageCreation }
        let width = Int((document.canvasSize.width * scale).rounded())
        let height = Int((document.canvasSize.height * scale).rounded())
        let context = try ImageUtilities.context(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        for item in document.commands { draw(item, in: context, base: base, size: document.canvasSize) }
        guard let image = context.makeImage() else { throw AppError.imageCreation }
        return image
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        if let first = points.first { path.move(to: first); for point in points.dropFirst() { path.addLine(to: point) } }
        return path
    }

    private static func draw(_ item: AnnotationItem, in context: CGContext, base: CGImage, size: CGSize) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(item.color.cgColor); context.setFillColor(item.color.cgColor)
        context.setLineWidth(item.width); context.setLineCap(.round); context.setLineJoin(.round)
        switch item.tool {
        case .rectangle: context.stroke(item.rect)
        case .ellipse: context.strokeEllipse(in: item.rect)
        case .line, .pen, .arrow:
            context.addPath(path(item.points)); context.strokePath()
            if item.tool == .arrow, let start = item.points.first, let end = item.points.last {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(10, item.width * 4)
                let arrow = CGMutablePath(); arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                arrow.move(to: end); arrow.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                context.addPath(arrow); context.strokePath()
            }
        case .highlight:
            context.setAlpha(0.28); context.fill(item.rect)
        case .mosaic, .blur:
            // Core Image calls the built-in pixelation filter CIPixellate (the prompt's CITilePixellate does not exist).
            guard let snapshot = context.makeImage() else { return }
            let source = CIImage(cgImage: snapshot).clampedToExtent()
            let pixelScale = abs(context.ctm.a)
            let filter = item.tool == .mosaic ? "CIPixellate" : "CIGaussianBlur"
            let key = item.tool == .mosaic ? kCIInputScaleKey : kCIInputRadiusKey
            let processed = source.applyingFilter(filter, parameters: [key: max(8, item.width * 4) * pixelScale]).cropped(to: CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
            if let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(processed, from: processed.extent) {
                if item.points.count > 2 { context.addPath(path(item.points)); context.setLineWidth(max(14, item.width * 6)); context.replacePathWithStrokedPath(); context.clip() }
                else { context.clip(to: item.rect) }
                context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
        case .text, .note:
            if item.tool == .note {
                context.setFillColor(CGColor(red: 1, green: 0.92, blue: 0.48, alpha: 0.98)); context.fill(item.rect)
            }
            text(item.text, font: item.font, color: item.tool == .note ? CGColor(gray: 0.1, alpha: 1) : item.color.cgColor, rect: item.rect.insetBy(dx: item.tool == .note ? 8 : 0, dy: item.tool == .note ? 8 : 0), context: context)
        case .step:
            let rect = CGRect(x: item.rect.midX - 14, y: item.rect.midY - 14, width: 28, height: 28)
            context.fillEllipse(in: rect)
            text(String(item.number), font: FontSnapshot(postScriptName: "Helvetica-Bold", pointSize: 18), color: CGColor(gray: 1, alpha: 1), rect: CGRect(x: rect.minX + 7, y: rect.minY + 2, width: 26, height: 26), context: context)
        case .magnifier:
            let scale = CGFloat(base.width) / size.width
            let sample = CGRect(x: item.rect.midX * scale - item.rect.width * scale / 4, y: item.rect.midY * scale - item.rect.height * scale / 4, width: item.rect.width * scale / 2, height: item.rect.height * scale / 2).intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            context.addEllipse(in: item.rect); context.clip()
            if let image = base.cropping(to: sample) { context.saveGState(); context.translateBy(x: item.rect.minX, y: item.rect.maxY); context.scaleBy(x: 1, y: -1); context.draw(image, in: CGRect(origin: .zero, size: item.rect.size)); context.restoreGState() }
            context.resetClip(); context.strokeEllipse(in: item.rect)
        }
    }

    private static func text(_ value: String, font: FontSnapshot, color: CGColor, rect: CGRect, context: CGContext) {
        guard !rect.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font.postScriptName as CFString, font.pointSize, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let string = NSAttributedString(string: value, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
        CTFrameDraw(frame, context); context.restoreGState()
    }
}
