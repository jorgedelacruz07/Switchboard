import Foundation
import Darwin

enum MemoryUsage {
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static var label: String {
        guard let bytes = footprintBytes() else { return "Memory · Unavailable" }
        return "Memory · \(String(format: "%.1f", Double(bytes) / 1048576)) MiB footprint"
    }
}
