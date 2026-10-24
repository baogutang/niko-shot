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
        let captureURL = try XCTUnwrap(URL(string: "niko-shot://capture?type=region&delay=2"))
        XCTAssertEqual(try AutomationCommand.parse(url: captureURL), try AutomationCommand.parse(arguments: ["capture", "--region", "--delay", "2"]))
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

    func testURLsOnlyStartFlowsTheUserFinishesOnScreen() throws {
        // Any web page or sandboxed app can open these links; silent captures and file writes must be impossible.
        let rejected = ["niko-shot://capture?output=/tmp/s.png", "niko-shot://capture?type=region&output=~/Desktop/s.png",
            "niko-shot://scroll?output=/tmp/long.png", "niko-shot://record?output=/tmp/movie.mp4",
            "niko-shot://capture?type=window&window-id=42", "niko-shot://ocr?type=window&windowID=42",
            "niko-shot://capture?type=fullscreen", "niko-shot://ocr?type=fullscreen", "niko-shot://record?type=fullscreen",
            "niko-shot://translate", "niko-shot://translate?to=en", "niko-shot://last-ocr"]
        for value in rejected {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try AutomationCommand.parse(url: url), value) { error in
                guard case .invalidArguments(let message) = error as? AutomationError else { return XCTFail("\(value): \(error)") }
                XCTAssertTrue(message.hasPrefix("URL"), message)
            }
        }
        let window = try AutomationCommand.parse(url: try XCTUnwrap(URL(string: "niko-shot://capture?type=window&delay=1")))
        XCTAssertEqual(window.captureType, .window); XCTAssertNil(window.windowID); XCTAssertNil(window.outputPath)
        XCTAssertFalse(window.runsWithoutSelection)
        let ocr = try AutomationCommand.parse(url: try XCTUnwrap(URL(string: "niko-shot://ocr?type=region&auto-ocr=0")))
        XCTAssertEqual(ocr.action, .ocr); XCTAssertFalse(ocr.runsWithoutSelection)
        let record = try AutomationCommand.parse(url: try XCTUnwrap(URL(string: "niko-shot://record?type=window&format=gif")))
        XCTAssertEqual(record.captureType, .window); XCTAssertEqual(record.recordingFormat, .gif)
        XCTAssertEqual(try AutomationCommand.parse(url: try XCTUnwrap(URL(string: "niko-shot://scroll?delay=3"))).delay, 3)
    }

    func testOutputNeedsAMediaExtensionAndNeverTargetsHiddenPaths() throws {
        let rejected: [[String]] = [["capture", "--output", "~/Desktop/shot"], ["capture", "--output", "~/.zshrc"],
            ["capture", "--output", "~/.ssh/authorized_keys.png"], ["capture", "--output", "~/Desktop/.hidden.png"],
            ["scroll", "--output", "~/Desktop/long.txt"], ["ocr", "--clipboard", "--output", "~/Desktop/text"],
            ["record", "--output", "~/Desktop/movie.gif"], ["record", "--format", "gif", "--output", "~/Desktop/movie.mp4"],
            ["record", "--output", "~/Desktop/movie"], ["capture", "--output", "/tmp/.config/x.png"]]
        for arguments in rejected { XCTAssertThrowsError(try AutomationCommand.parse(arguments: arguments), "\(arguments)") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(try AutomationCommand.parse(arguments: ["capture", "--output", "~/Desktop/s.JPG"]).outputPath,
            home.appendingPathComponent("Desktop/s.JPG").path)
        for name in ["s.png", "s.jpeg", "s.heic", "s.heif", "s.tif", "s.tiff"] {
            XCTAssertNoThrow(try AutomationCommand.parse(arguments: ["scroll", "--output", "/tmp/\(name)"]), name)
        }
        XCTAssertNoThrow(try AutomationCommand.parse(arguments: ["record", "--output", "/tmp/movie.mov"]))
        XCTAssertNoThrow(try AutomationCommand.parse(arguments: ["record", "--output", "/tmp/movie.mp4"]))
        XCTAssertNoThrow(try AutomationCommand.parse(arguments: ["record", "--format", "gif", "--output", "/tmp/movie.gif"]))
        XCTAssertThrowsError(try AutomationCommand(action: .lastOCR, outputPath: "/tmp/text.png").validated())
        XCTAssertThrowsError(try AutomationCommand(action: .translate, outputPath: "/tmp/text.png").validated())

        // A visible symlink cannot smuggle a write into a hidden directory.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".secret"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("visible"), withDestinationURL: root.appendingPathComponent(".secret"))
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent(".secret/rc").path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("rc.png"), withDestinationURL: root.appendingPathComponent(".secret/rc"))
        for name in ["visible/x.png", "visible/new/x.png", "rc.png"] {
            XCTAssertThrowsError(try AutomationCommand(action: .capture, outputPath: root.appendingPathComponent(name).path).validated(), name)
        }
        XCTAssertNoThrow(try AutomationCommand(action: .capture, outputPath: root.appendingPathComponent("plain/x.png").path).validated())
    }

    func testRelativeOutputResolvesAgainstTheDesktopOutsideTheCLI() throws {
        let desktop = AutomationCommand.defaultOutputDirectory
        XCTAssertEqual(desktop.standardizedFileURL.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
        let command = try AutomationCommand(action: .capture, outputPath: "shots/../region.png").validated()
        XCTAssertEqual(command.outputPath, desktop.appendingPathComponent("region.png").standardizedFileURL.path)
        XCTAssertEqual(try command.validated(), command, "Revalidating an absolute path must not move it")
        let cli = try AutomationCommand.parse(arguments: ["capture", "--output", "region.png"])
        XCTAssertEqual(cli.outputPath, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("region.png").path)
    }

    @MainActor func testCommandLineCapturesWithoutSelectionNeedTheSilentAutomationSetting() throws {
        let silent = [AutomationCommand(action: .capture, captureType: .fullscreen),
            AutomationCommand(action: .capture, captureType: .window, windowID: 42),
            AutomationCommand(action: .ocr, captureType: .fullscreen), AutomationCommand(action: .ocr, captureType: .window, windowID: 7),
            AutomationCommand(action: .lastOCR)]
        for command in silent {
            XCTAssertTrue(command.runsWithoutSelection)
            XCTAssertThrowsError(try command.validatedForCommandLine(allowsSilentAutomation: false), "\(command)") { error in
                XCTAssertEqual(error as? AutomationError, .silentAutomationDisabled)
                XCTAssertEqual(error.localizedDescription, "命令行静默截图未开启：在 设置 → 通用 打开「允许命令行静默截图」。")
            }
            XCTAssertNoThrow(try command.validatedForCommandLine(allowsSilentAutomation: true))
        }
        let interactive = [AutomationCommand(action: .capture), AutomationCommand(action: .capture, captureType: .window),
            AutomationCommand(action: .ocr), AutomationCommand(action: .scroll), AutomationCommand(action: .translate),
            AutomationCommand(action: .record, captureType: .fullscreen, recordingFormat: .gif)]
        for command in interactive {
            XCTAssertFalse(command.runsWithoutSelection)
            XCTAssertNoThrow(try command.validatedForCommandLine(allowsSilentAutomation: false), "\(command)")
        }
        XCTAssertThrowsError(try AutomationCommand(action: .capture, delay: 11).validatedForCommandLine(allowsSilentAutomation: true))
        let suite = "niko-shot.silent-automation.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.allowsSilentAutomation, "Silent CLI capture is off until the user opts in")
        settings.allowsSilentAutomation = true
        XCTAssertTrue(AppSettings(defaults: defaults).allowsSilentAutomation)
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
