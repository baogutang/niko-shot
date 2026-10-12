// Guards app identity, the minimum OS and the native menu entry point.
import XCTest
@testable import NikoShot

final class BootstrapTests: XCTestCase {
    func testBundleIdentity() {
        XCTAssertEqual(Bundle(for: AppDelegate.self).bundleIdentifier, "com.n1ko.niko-shot")
    }
}
