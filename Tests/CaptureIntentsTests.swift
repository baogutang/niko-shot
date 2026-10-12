// Executes real AppIntent perform methods against a fixture bridge, with no TCC or device access.
import AppIntents
import Foundation
import XCTest
@testable import NikoShot

@MainActor
final class CaptureIntentsTests: XCTestCase {
    func testAllFiveIntentsRouteToResidentAndReturnPathsOrText() async throws {
        let bridge = AutomationBridge.shared, prior = bridge.handler, recorder = AutomationCommandRecorder()
        defer { bridge.handler = prior }
        bridge.handler = { command in
            recorder.commands.append(command)
            return command.action == .lastOCR ? AutomationResponse(text: "上次 OCR\n第二行") : AutomationResponse(outputPath: "/tmp/fixture-output", message: "完成")
        }
        let region = CaptureRegionIntent(); region.delay = 2; region.outputPath = "~/Desktop/region.png"; region.autoOCR = false
        let window = CaptureWindowIntent(); window.delay = 3; window.outputPath = "/tmp/window.png"; window.autoOCR = true; window.windowID = 42
        let recording = StartRecordingIntent(); recording.delay = 4; recording.outputPath = "/tmp/movie.gif"; recording.autoOCR = false; recording.format = .gif
        let scroll = ScrollCaptureIntent(); scroll.delay = 5; scroll.outputPath = "/tmp/long.png"; scroll.autoOCR = true
        let regionResult = try await region.perform(), windowResult = try await window.perform()
        let recordingResult = try await recording.perform(), scrollResult = try await scroll.perform()
        let textResult = try await LastOCRTextIntent().perform()
        XCTAssertEqual(regionResult.value, "/tmp/fixture-output"); XCTAssertEqual(windowResult.value, "/tmp/fixture-output")
        XCTAssertEqual(recordingResult.value, "/tmp/fixture-output"); XCTAssertEqual(scrollResult.value, "/tmp/fixture-output")
        XCTAssertEqual(textResult.value, "上次 OCR\n第二行")
        XCTAssertEqual(recorder.commands.map(\.action), [.capture, .capture, .record, .scroll, .lastOCR])
        XCTAssertEqual(recorder.commands.map(\.delay), [2, 3, 4, 5, 0])
        XCTAssertEqual(recorder.commands.map(\.autoOCR), [false, true, false, true, true])
        XCTAssertEqual(recorder.commands[0].outputPath, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/region.png").path)
        XCTAssertEqual(recorder.commands[1].captureType, .window); XCTAssertEqual(recorder.commands[1].windowID, 42)
        XCTAssertEqual(recorder.commands[2].recordingFormat, .gif)
        XCTAssertTrue(CaptureRegionIntent.openAppWhenRun && CaptureWindowIntent.openAppWhenRun && StartRecordingIntent.openAppWhenRun && ScrollCaptureIntent.openAppWhenRun && LastOCRTextIntent.openAppWhenRun)
    }

    func testInvalidShortcutParametersNeverReachCaptureHandler() async throws {
        let bridge = AutomationBridge.shared, prior = bridge.handler, recorder = AutomationCommandRecorder()
        defer { bridge.handler = prior }
        bridge.handler = { command in recorder.commands.append(command); return AutomationResponse() }
        let region = CaptureRegionIntent(); region.delay = 11; region.outputPath = nil; region.autoOCR = true
        do { _ = try await region.perform(); XCTFail("Expected invalid delay") } catch { XCTAssertTrue(error is AutomationError) }
        let window = CaptureWindowIntent(); window.delay = 0; window.outputPath = nil; window.autoOCR = true
        for id in [-1, 0, Int(UInt32.max) + 1] {
            window.windowID = id
            do { _ = try await window.perform(); XCTFail("Expected invalid window ID") } catch { XCTAssertTrue(error is AutomationError) }
        }
        let scroll = ScrollCaptureIntent(); scroll.delay = 0; scroll.outputPath = ""; scroll.autoOCR = true
        do { _ = try await scroll.perform(); XCTFail("Expected invalid output") } catch { XCTAssertTrue(error is AutomationError) }
        XCTAssertTrue(recorder.commands.isEmpty)
    }
}
