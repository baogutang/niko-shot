// Encodes system-supported image formats with metadata and controlled JPEG quality.
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpeg, heif, tiff
    var type: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .heif: .heic; case .tiff: .tiff } }
    var fileExtension: String { switch self { case .png: "png"; case .jpeg: "jpg"; case .heif: "heic"; case .tiff: "tiff" } }
}

enum Exporters {
    /// Encodes a raster on a worker task, preserving PNG/TIFF alpha and EXIF capture time.
    /// `scale` is the capture's backing scale, written as 72 × scale DPI so a Retina capture opens at its
    /// on-screen size in Preview and Keynote rather than at 200%.
    static func encode(_ image: CGImage, format: ExportFormat, quality: Double = 0.9, date: Date = .now, scale: CGFloat = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { throw AppError.file("系统不支持此格式编码。") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dpi = 72 * max(1, scale)
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: formatter.string(from: date), kCGImagePropertyTIFFSoftware: "niko-shot"]]
        if format == .jpeg || format == .heif { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        var output = image
        if format == .jpeg {
            let context = try ImageUtilities.context(width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw AppError.imageCreation }
            output = flattened
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.file("图像编码失败。") }
        return data as Data
    }

    /// Downsamples an encoded capture using ImageIO instead of decoding it into a full-size UI image.
    static func thumbnail(from data: Data, maxPixel: Int = 240) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw AppError.imageCreation }
        return try ImageUtilities.png(thumbnail)
    }

    static func filename(template: String, date: Date, sequence: Int, format: ExportFormat) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"; let time = formatter.string(from: date)
        let name = template.replacingOccurrences(of: "{date}", with: day).replacingOccurrences(of: "{time}", with: time).replacingOccurrences(of: "{n}", with: String(sequence)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (name.isEmpty ? "niko-shot" : name) + "." + format.fileExtension
    }

    /// A destination in `folder` that never replaces an existing file: "name.png", then "name 2.png", …
    static func uniqueURL(in folder: URL, filename: String, fileManager: FileManager = .default) -> URL {
        let base = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}
