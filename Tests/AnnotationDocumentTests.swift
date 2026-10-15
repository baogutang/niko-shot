// Checks command persistence, font snapshots, undo branches and arbitrary-scale rasterization.
import XCTest
@testable import NikoShot

final class AnnotationDocumentTests: XCTestCase {
    func testFontSnapshotSerializationAndUndoRedo() throws {
        var document = AnnotationDocument(canvasSize: CGSize(width: 100, height: 100))
        var item = AnnotationItem(tool: .text, rect: CGRect(x: 5, y: 5, width: 90, height: 80), text: "中文 日本語 English")
        item.font = FontSnapshot(postScriptName: "Menlo-Regular", pointSize: 16)
        document.append(item)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.commands, document.commands)
        XCTAssertEqual(decoded.commands.first?.font, item.font)
        document.undo(); XCTAssertTrue(document.commands.isEmpty)
        document.redo(); XCTAssertEqual(document.commands, [item])
        document.undo(); document.append(AnnotationItem(tool: .rectangle)); XCTAssertFalse(document.canRedo)
    }
    func testEveryToolRendersAtRetinaScale() throws {
        let baseContext = try ImageUtilities.context(width: 80, height: 80)
        baseContext.setFillColor(CGColor(gray: 0.9, alpha: 1)); baseContext.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let base = try XCTUnwrap(baseContext.makeImage())
        for tool in AnnotationTool.allCases {
            var document = AnnotationDocument(canvasSize: CGSize(width: 80, height: 80))
            document.append(AnnotationItem(tool: tool, rect: CGRect(x: 10, y: 10, width: 40, height: 40), points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)], text: "Text"))
            let result = try AnnotationRenderer.render(base: base, document: document, scale: 2)
            XCTAssertEqual(result.width, 160, tool.rawValue); XCTAssertEqual(result.height, 160, tool.rawValue)
        }
    }
    func testNoCommandsPreserveImageOrientationAndPixels() throws {
        let context = try ImageUtilities.context(width: 20, height: 20)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return XCTFail("No pixels") }
        for y in 0..<20 { for x in 0..<20 {
            let offset = y * context.bytesPerRow + x * 4
            bytes[offset] = UInt8(y * 10); bytes[offset + 1] = UInt8(x * 10); bytes[offset + 2] = 0; bytes[offset + 3] = 255
        } }
        let base = try XCTUnwrap(context.makeImage())
        let result = try AnnotationRenderer.render(base: base, document: AnnotationDocument(canvasSize: CGSize(width: 20, height: 20)), scale: 1)
        XCTAssertEqual(base.dataProvider?.data as Data?, result.dataProvider?.data as Data?)
    }
    func testBlurPreservesUnderlyingEarlierAnnotationsAtEachScale() throws {
        let context = try ImageUtilities.context(width: 80, height: 80)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let base = try XCTUnwrap(context.makeImage())
        var document = AnnotationDocument(canvasSize: CGSize(width: 80, height: 80))
        document.append(AnnotationItem(tool: .rectangle, color: .red, rect: CGRect(x: 10, y: 10, width: 60, height: 60), filled: true))
        document.append(AnnotationItem(tool: .blur, width: 1, rect: CGRect(x: 30, y: 30, width: 20, height: 20)))
        for scale: CGFloat in [1, 2] {
            let image = try AnnotationRenderer.render(base: base, document: document, scale: scale)
            let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
            let offset = Int(40 * scale) * image.bytesPerRow + Int(40 * scale) * 4
            XCTAssertGreaterThan(bytes[offset], 30, "An effect must operate on preceding document commands")
        }
    }

}
