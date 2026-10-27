import Foundation
import Darwin

public struct SystemSnapshot: Sendable {
    public var cpu: Double = 0
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var diskFree: UInt64 = 0
    public var diskTotal: UInt64 = 0
    public var pressure: Int32 = 0
    public var date = Date()
    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }
    public init() {}
}

public struct CPUSample: Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    public func utilization(since old: CPUSample) -> Double {
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        return total > 0 ? Double(busy) / Double(total) : 0
    }
}

public enum Metrics {
    public static func read(previous: CPUSample?) -> (SystemSnapshot, CPUSample) {
        var result = SystemSnapshot()
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpu) / MemoryLayout<integer_t>.size)
        let cpuOK = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        let ticks = cpu.cpu_ticks
        let sample = cpuOK == KERN_SUCCESS ? CPUSample(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3) : previous ?? CPUSample(user: 0, system: 0, idle: 0, nice: 0)
        if let previous { result.cpu = sample.utilization(since: previous) }
        result.memoryTotal = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmOK = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if vmOK == KERN_SUCCESS {
            let occupied = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let reclaimable = UInt64(vm.purgeable_count) + UInt64(vm.external_page_count)
            result.memoryUsed = min(result.memoryTotal, (occupied > reclaimable ? occupied - reclaimable : 0) * UInt64(vm_kernel_page_size))
        }
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout.size(ofValue: pressure)
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 { result.pressure = pressure }
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { result.swapUsed = swap.xsu_used }
        var disk = statvfs()
        if statvfs("/System/Volumes/Data", &disk) == 0 {
            result.diskTotal = UInt64(disk.f_blocks) * UInt64(disk.f_frsize)
            result.diskFree = UInt64(disk.f_bavail) * UInt64(disk.f_frsize)
        }
        return (result, sample)
    }
}

public enum DisplayFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
}
