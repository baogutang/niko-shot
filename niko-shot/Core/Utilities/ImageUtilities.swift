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

    /// Allocates a deterministic RGBA image for tests and offscreen rendering.
    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.imageCreation }
        return context
    }
}
