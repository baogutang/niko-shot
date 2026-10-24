// Verifies ImageIO output dimensions, alpha, thumbnail size, JPEG EXIF time and Retina DPI.
import AppKit
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

    func testBackingScaleIsWrittenAsDPISoRetinaCapturesOpenAtTheirOnScreenSize() throws {
        let context = try ImageUtilities.context(width: 64, height: 32)
        let image = try XCTUnwrap(context.makeImage())
        for format in ExportFormat.allCases {
            for (scale, dpi) in [(CGFloat(1), 72.0), (2, 144)] {
                let data = try scale == 1 ? Exporters.encode(image, format: format) : Exporters.encode(image, format: format, scale: scale)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi, "\(format) @\(scale)x")
                XCTAssertEqual((properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue, dpi, "\(format) @\(scale)x")
                XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 64, "DPI never resamples pixels")
            }
        }
        let retina = try Exporters.encode(image, format: .png, scale: 2)
        XCTAssertEqual(NSImage(data: retina)?.size, CGSize(width: 32, height: 16))
    }
}

final class AutoSaveNamingTests: XCTestCase {
    func testUniqueURLNeverReplacesAnExistingCapture() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Exporters.uniqueURL(in: folder, filename: "niko-shot 2026-10-24.png")
        XCTAssertEqual(first.lastPathComponent, "niko-shot 2026-10-24.png")
        try Data([1]).write(to: first)
        let second = Exporters.uniqueURL(in: folder, filename: "niko-shot 2026-10-24.png")
        XCTAssertEqual(second.lastPathComponent, "niko-shot 2026-10-24 2.png")
        try Data([2]).write(to: second)
        XCTAssertEqual(Exporters.uniqueURL(in: folder, filename: "niko-shot 2026-10-24.png").lastPathComponent, "niko-shot 2026-10-24 3.png")
    }

    @MainActor func testAutoSaveFolderPersistsAndDefaultsOff() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "com.n1ko.niko-shot.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: store)
        XCTAssertTrue(settings.autoSaveFolder.isEmpty)
        settings.autoSaveFolder = "/tmp/captures"
        XCTAssertEqual(AppSettings(defaults: store).autoSaveFolder, "/tmp/captures")
    }
}
