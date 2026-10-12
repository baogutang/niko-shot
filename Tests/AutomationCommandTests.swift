// Tests CLI/URL contracts and rejects malformed commands without invoking capture or permissions.
import Foundation
import XCTest
@testable import NikoShot

final class AutomationCommandTests: XCTestCase {
    func testDocumentedCommandsAndURLsShareOneContract() throws {
        let capture = try AutomationCommand.parse(arguments: ["capture", "--region", "--delay", "2", "--output", "~/Desktop/s.png"])
        XCTAssertEqual(capture.action, .capture)
        XCTAssertEqual(capture.delay, 2)
        XCTAssertEqual(capture.outputPath, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/s.png").path)
        XCTAssertTrue(capture.autoOCR)
        let captureURL = try XCTUnwrap(URL(string: "niko-shot://capture?type=region&delay=2&output=~/Desktop/s.png"))
        XCTAssertEqual(try AutomationCommand.parse(url: captureURL), capture)
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["ocr", "--clipboard"]).action, .ocr)
        let translation = try AutomationCommand.parse(arguments: ["translate", "--to", "zh"])
        XCTAssertEqual(translation.action, .translate); XCTAssertEqual(translation.targetLanguage, "zh")
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["translate"]).targetLanguage, "zh")
        let gifURL = try XCTUnwrap(URL(string: "niko-shot://record?format=gif"))
        XCTAssertEqual(try AutomationCommand.parse(url: gifURL).recordingFormat, .gif)
        let scrollURL = try XCTUnwrap(URL(string: "niko-shot://scroll"))
        XCTAssertEqual(try AutomationCommand.parse(url: scrollURL).action, .scroll)
    }

    func testWindowIdentifiersRelativePathsAndLanguageAliasesNormalize() throws {
        let command = try AutomationCommand.parse(arguments: ["capture", "--window", "--window-id", "42", "--no-auto-ocr", "--output", "build/../capture.png"])
        XCTAssertEqual(command.captureType, .window); XCTAssertEqual(command.windowID, 42); XCTAssertFalse(command.autoOCR)
        XCTAssertEqual(command.outputPath, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("capture.png").path)
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["translate", "--to", "zh-TW"]).targetLanguage, "zh-Hant")
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["last-ocr"]).action, .lastOCR)
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["capture", "--delay", "02"]).delay, 2)
        let response = AutomationResponse(outputPath: "/tmp/output.png", text: "识别结果", message: "完成")
        XCTAssertEqual(try JSONDecoder().decode(AutomationResponse.self, from: JSONEncoder().encode(response)), response)
        XCTAssertEqual(try JSONDecoder().decode(AutomationCommand.self, from: JSONEncoder().encode(command)), command)
    }

    func testCLIRejectsInvalidUnknownDuplicateAndInapplicableArguments() {
        let invalid: [[String]] = [[], ["delete"], ["capture", "--delay", "-1"], ["capture", "--delay", "11"],
            ["capture", "--delay", "1.5"], ["capture", "--delay"],
            ["capture", "--region", "--window"], ["capture", "--region", "--region"], ["capture", "--output", ""],
            ["capture", "--output", "/"], ["capture", "--output", "a\nb.png"], ["capture", "--unknown"],
            ["capture", "--output", "a.png", "--output", "b.png"], ["capture", "--auto-ocr", "--no-auto-ocr"],
            ["capture", "--window-id", "42"], ["capture", "--window", "--window-id", "0"],
            ["capture", "--window", "--window-id", "4294967296"], ["record", "--format", "webm"],
            ["record", "--format", "gif", "--format", "mp4"], ["capture", "--format", "mp4"],
            ["translate", "--to", "zz"], ["translate", "--clipboard"], ["scroll", "--fullscreen"],
            ["last-ocr", "--delay", "1"], ["ocr", "--clipboard", "--clipboard"]]
        for arguments in invalid { XCTAssertThrowsError(try AutomationCommand.parse(arguments: arguments), "\(arguments)") }
    }

    func testURLsRejectDuplicateAndSpoofedRouting() throws {
        let invalid = ["https://capture?type=region", "niko-shot://delete", "niko-shot://capture/extra", "niko-shot://capture#fragment",
            "niko-shot://user@capture", "niko-shot://capture:42", "niko-shot://capture?delay=1&delay=2",
            "niko-shot://capture?type=screen", "niko-shot://capture?delay=-1", "niko-shot://capture?delay=11",
            "niko-shot://capture?delay", "niko-shot://capture?output=", "niko-shot://capture?text=secret",
            "niko-shot://capture?autoOCR=maybe", "niko-shot://capture?autoOCR=true&auto-ocr=false",
            "niko-shot://record?format=mov", "niko-shot://scroll?type=window", "niko-shot://capture?to=en"]
        for value in invalid {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try AutomationCommand.parse(url: url), value)
        }
    }

    @MainActor func testBridgeValidatesBeforeHandlerAndReportsUnavailable() async throws {
        let bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        do { _ = try await bridge.execute(AutomationCommand(action: .capture)); XCTFail("Expected unavailable bridge") }
        catch { XCTAssertEqual(error as? AutomationError, .unavailable) }
        bridge.handler = { command in recorder.commands.append(command); return AutomationResponse(message: "fixture") }
        do { _ = try await bridge.execute(AutomationCommand(action: .capture, delay: 11)); XCTFail("Expected validation failure") }
        catch { XCTAssertTrue(error is AutomationError) }
        XCTAssertTrue(recorder.commands.isEmpty)
        let command = AutomationCommand(action: .translate, targetLanguage: "ZH-HANT")
        _ = try await bridge.execute(command)
        XCTAssertEqual(recorder.commands.map(\.targetLanguage), ["zh-Hant"])
    }
}

@MainActor final class AutomationCommandRecorder { var commands: [AutomationCommand] = [] }
