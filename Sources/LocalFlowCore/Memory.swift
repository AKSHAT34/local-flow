import Foundation
#if canImport(MachO)
import MachO
#endif

public enum MemoryProbe {
    /// Best-effort phys_footprint for this process. Returns nil if task_info is unavailable.
    public static func physFootprintBytes() -> UInt64? {
        #if canImport(MachO)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        if result == KERN_SUCCESS {
            return info.phys_footprint
        }
        #endif
        return nil
    }

    public static func currentMB() -> Double? {
        physFootprintBytes().map { Double($0) / 1_048_576.0 }
    }
}
