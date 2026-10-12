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

}
