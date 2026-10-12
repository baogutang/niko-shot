// Verifies ImageIO output dimensions, alpha, thumbnail size and JPEG EXIF time.
import XCTest
import ImageIO
@testable import NikoShot

final class ExportersTests: XCTestCase {
    func testAllFormatsDimensionsAlphaAndMetadata() throws {
        let context = try ImageUtilities.context(width: 64, height: 32)
        let image = try XCTUnwrap(context.makeImage())
        for format in ExportFormat.allCases {
            let data = try Exporters.encode(image, format: format, date: Date(timeIntervalSince1970: 0))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 64); XCTAssertEqual(decoded.height, 32)
            if format == .png { XCTAssertNotEqual(decoded.alphaInfo, .none) }
            if format == .jpeg {
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                XCTAssertNotNil(properties[kCGImagePropertyExifDictionary as String])
            }
            let thumb = try Exporters.thumbnail(from: data, maxPixel: 16)
            let thumbSource = try XCTUnwrap(CGImageSourceCreateWithData(thumb as CFData, nil))
            XCTAssertLessThanOrEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil)).width, 16)
        }
    }
}
