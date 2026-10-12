// Resolves all app-owned storage beneath Application Support without sandbox bookmarks.
import Foundation

enum AppPaths {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("niko-shot", isDirectory: true) }
    static var captures: URL { root.appendingPathComponent("Captures", isDirectory: true) }
    static var pins: URL { root.appendingPathComponent("Pins", isDirectory: true) }
}
