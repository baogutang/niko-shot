// Performs ImageIO encoding and image allocation away from the main actor.
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageUtilities {
    /// Encodes PNG using only ImageIO; call from a worker task for full-size images.
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AppError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.imageCreation }
        return data as Data
    }

    /// A crop that owns its pixels. `CGImage.cropping(to:)` shares the parent buffer, so a small
    /// selection kept by the clipboard or a pin would otherwise hold the whole frozen display alive.
    static func ownedCrop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect) else { return nil }
        // Near-full crops gain nothing from a copy.
        guard crop.width * crop.height * 2 < image.width * image.height,
              let space = crop.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return crop }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage() ?? crop
    }

    /// Allocates a deterministic RGBA image for tests and offscreen rendering.
    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.imageCreation }
        return context
    }
}
