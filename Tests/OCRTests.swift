// Checks text transforms and real Vision recognition against a deterministic rendered fixture.
import XCTest
@testable import NikoShot

final class OCRTests: XCTestCase {
    func testPunctuationAndLineTransform() {
        XCTAssertEqual(OCRTextProcessor.process("你好，世界！\n（测试）", mergeParagraphs: false, stripLineBreaks: true, englishPunctuation: true), "你好,世界!(测试)")
        XCTAssertEqual(OCRTextProcessor.process("one\ntwo", mergeParagraphs: true, stripLineBreaks: false, englishPunctuation: false), "one two")
    }
    func testVisionRecognizesRenderedText() async throws {
        let context = try ImageUtilities.context(width: 600, height: 150)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 150))
        let base = try XCTUnwrap(context.makeImage())
        var document = AnnotationDocument(canvasSize: CGSize(width: 600, height: 150))
        document.append(AnnotationItem(tool: .text, color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1), rect: CGRect(x: 20, y: 20, width: 560, height: 110), text: "NIKO SHOT 2026", font: FontSnapshot(postScriptName: "Helvetica", pointSize: 42)))
        let fixture = try AnnotationRenderer.render(base: base, document: document, scale: 1)
        let blocks = try await OCREngine().recognize(fixture, languages: ["en-US"])
        XCTAssertTrue(blocks.map(\.text).joined(separator: " ").contains("NIKO"))
        XCTAssertTrue(blocks.allSatisfy { $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 })
    }
}
