// Exercises real CoreVideo surfaces, color/orientation, idle caching and stream teardown without TCC.
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import NikoShot

final class ScrollFrameBufferTests: XCTestCase {
    func testCompleteFrameKeepsNativePixelsAndTopDownCrop() throws {
        let buffer = ScrollFrameBuffer()
        buffer.receive(try pixels(), status: .complete)
        let full = try XCTUnwrap(buffer.image())
        XCTAssertEqual(full.width, 16); XCTAssertEqual(full.height, 8)
        try assertPixel(full, x: 3, y: 0, red: 0, green: 30)
        try assertPixel(full, x: 3, y: 7, red: 70, green: 30)
        let crop = try XCTUnwrap(buffer.image(crop: CGRect(x: 2, y: 2, width: 6, height: 3)))
        XCTAssertEqual(crop.width, 6); XCTAssertEqual(crop.height, 3)
        try assertPixel(crop, x: 0, y: 0, red: 20, green: 20)
        try assertPixel(crop, x: 5, y: 2, red: 40, green: 70)
        buffer.close()
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        XCTAssertEqual(buffer.renderedFrameCount, 0)
    }

    func testIdleReusesOneDecodedImageAndLatestFramesNeverQueueUp() throws {
        let buffer = ScrollFrameBuffer()
        buffer.receive(try pixels(), status: .started)
        XCTAssertNil(try buffer.image(), "Only complete compositor frames supply pixels")
        buffer.receive(try pixels(), status: .complete)
        let first = try XCTUnwrap(buffer.image())
        buffer.receive(nil, status: .idle)
        XCTAssertTrue(try buffer.image() === first)
        for offset in 1...20 { buffer.receive(try pixels(offset: UInt8(offset)), status: .complete) }
        XCTAssertEqual(buffer.retainedFrameCount, 1)
        let latest = try XCTUnwrap(buffer.image())
        try assertPixel(latest, x: 0, y: 0, red: 20, green: 0)
        XCTAssertEqual(buffer.renderedFrameCount, 1)
        buffer.close()
    }

    func testUnavailableFramesNeverReturnAnOldSuccessfulImage() throws {
        let buffer = ScrollFrameBuffer()
        buffer.receive(try pixels(), status: .complete)
        XCTAssertNotNil(try buffer.image())
        buffer.receive(nil, status: .suspended)
        XCTAssertThrowsError(try buffer.image())
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        buffer.receive(try pixels(offset: 7), status: .complete)
        try assertPixel(try XCTUnwrap(buffer.image()), x: 0, y: 0, red: 7, green: 0)
        buffer.receive(nil, status: .blank)
        XCTAssertThrowsError(try buffer.image())
        buffer.close()
        buffer.receive(try pixels(), status: .complete)
        XCTAssertThrowsError(try buffer.image())
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        XCTAssertEqual(buffer.renderedFrameCount, 0)
    }

    @MainActor
    func testSessionSnapshotStopsExactlyOnceAndRejectsLatePixels() async throws {
        let buffer = ScrollFrameBuffer()
        buffer.receive(try pixels(), status: .complete)
        let image = try XCTUnwrap(buffer.image())
        var stops = 0
        let snapshot = RegionSnapshot(capture: { image }, stop: { stops += 1 }, continuous: true)
        XCTAssertTrue(snapshot.isStreaming)
        _ = try await snapshot.capture()
        await snapshot.stop(); await snapshot.stop()
        XCTAssertFalse(snapshot.isStreaming)
        XCTAssertEqual(stops, 1)
        do { _ = try await snapshot.capture(); XCTFail("Closed streams must not reactivate") }
        catch is CancellationError {} catch { XCTFail("Unexpected closed-stream error: \(error)") }
        buffer.close()
    }

    private func pixels(offset: UInt8 = 0) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVBufferSetAttachment(pixels, kCVImageBufferCGColorSpaceKey,
            try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<8 { for x in 0..<16 {
            let i = y * stride + x * 4
            bytes[i] = 25; bytes[i + 1] = UInt8(x * 10); bytes[i + 2] = UInt8(y * 10) + offset; bytes[i + 3] = 255
        } }
        return pixels
    }

    private func assertPixel(_ image: CGImage, x: Int, y: Int, red: Int, green: Int,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let i = y * image.bytesPerRow + x * 4
        XCTAssertLessThanOrEqual(abs(Int(data[i]) - red), 1, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(data[i + 1]) - green), 1, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(data[i + 2]) - 25), 1, file: file, line: line)
        XCTAssertEqual(data[i + 3], 255, file: file, line: line)
    }
}
