// Boots the single menu bar process; automation is routed before app startup.
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
