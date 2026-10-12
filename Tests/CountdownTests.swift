// Checks that cancelling a delayed operation destroys its countdown and local listener immediately.
import XCTest
@testable import NikoShot

@MainActor
final class CountdownTests: XCTestCase {
    func testCancellationRemovesWindowAndMonitorWithoutWaitingForNextSecond() async {
        let countdown = CaptureCountdown()
        let operation = Task { try await countdown.wait(seconds: 10) }
        for _ in 0..<20 {
            if countdown.windowCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(countdown.windowCount, 1)
        XCTAssertEqual(countdown.monitorCount, 1)
        countdown.cancel()
        XCTAssertEqual(countdown.windowCount, 0)
        XCTAssertEqual(countdown.monitorCount, 0)
        do { try await operation.value; XCTFail("Cancelled countdown completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
