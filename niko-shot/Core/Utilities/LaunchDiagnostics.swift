// Reports opt-in launch resident-memory checkpoints without adding an idle sampler.
import Darwin
import Foundation

enum LaunchDiagnostics {
    static func record(_ stage: String) {
        guard ProcessInfo.processInfo.environment["NIKO_LAUNCH_DIAGNOSTICS"] == "1" else { return }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        try? FileHandle.standardError.write(contentsOf: Data("launch-rss \(stage) \(info.resident_size)\n".utf8))
    }
}
