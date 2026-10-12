// Verifies session teardown on synthetic screens without requesting recording permissions.
import XCTest
@testable import NikoShot

@MainActor
final class SelectionSessionTests: XCTestCase {
    func testFinishRemovesWindowsListenersAndFrozenFrames() throws {
        let context = try ImageUtilities.context(width: 20, height: 20)
        let image = try XCTUnwrap(context.makeImage())
        var session: SelectionSession? = SelectionSession()
        weak let weakSession = session
        session?.start(frames: [FrozenFrame(screen: ScreenGeometry(id: 1, frame: CGRect(x: -100, y: -100, width: 10, height: 10), scale: 2), image: image)]) { _, _ in }
        XCTAssertEqual(session?.windowCount, 1)
        XCTAssertEqual(session?.monitorCount, 1)
        session?.finish()
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        XCTAssertEqual(session?.frameCount, 0)
        XCTAssertEqual(session?.state, .idle)
        session = nil
        XCTAssertNil(weakSession)
    }
    func testImageEditorTearsDownItsWindowAndToolbar() throws {
        let context = try ImageUtilities.context(width: 64, height: 128)
        let image = try XCTUnwrap(context.makeImage())
        var session: SelectionSession? = SelectionSession()
        weak let weakSession = session
        session?.edit(image: image, pointSize: CGSize(width: 32, height: 64)) { _, _ in }
        XCTAssertEqual(session?.state, .annotating)
        XCTAssertEqual(session?.windowCount, 2)
        XCTAssertEqual(session?.monitorCount, 1)
        session?.finish()
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        session = nil
        XCTAssertNil(weakSession)
    }

    func testRecordingSelectionCancelIsReportedOnceAndLeavesNoResources() throws {
        let context = try ImageUtilities.context(width: 64, height: 64)
        let image = try XCTUnwrap(context.makeImage())
        let geometry = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 32, height: 32), scale: 2)
        let session = SelectionSession()
        session.start(frames: [FrozenFrame(screen: geometry, image: image)],
                      initial: CaptureContext(screen: geometry, localRect: CGRect(x: 2, y: 2, width: 20, height: 20)),
                      autoConfirm: false, confirmationTitle: "开始录制") { _, _ in XCTFail("Cancellation produced capture output") }
        var completions: [Bool] = []
        session.onFinish = { completions.append($0) }
        session.beginAnnotation(tool: .rectangle)
        XCTAssertEqual(session.state, .selected)
        session.finish(); session.finish()
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertEqual(session.monitorCount, 0)
        XCTAssertEqual(session.frameCount, 0)
    }

}
