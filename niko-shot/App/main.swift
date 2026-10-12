// Boots the single menu bar process; automation is routed before app startup.
import AppKit

if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
   let code = AutomationCLI.runIfNeeded(arguments: CommandLine.arguments) { exit(code) }
let residentLock: ResidentInstanceLock?
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    do {
        guard let lock = try ResidentInstanceLock.acquire() else {
            if let pid = ResidentInstanceLock.currentPID() {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
            exit(0)
        }
        residentLock = lock
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data("无法启动 niko-shot：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else { residentLock = nil }
LaunchDiagnostics.record("before-application")
let application = NSApplication.shared
LaunchDiagnostics.record("application-created")
let delegate = AppDelegate()
LaunchDiagnostics.record("delegate-created")
application.delegate = delegate
withExtendedLifetime(residentLock) { application.run() }
