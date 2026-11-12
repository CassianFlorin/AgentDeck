import Darwin
import Foundation
import IOKit

/// Raw readings for one tick. A field is nil when its monitor is off, or when
/// it is a rate and there is no previous sample to diff against yet.
struct PerfReadings {
    var cpu: CPUReading?
    var memory: MemoryReading?
    var network: IORate?
    var disk: DiskReading?
    var gpu: GPUReading?
    var sessions: SessionsReading?
}

struct CPUReading {
    var user: Double       // 0…1
    var system: Double     // 0…1
    var perCore: [Double]  // 0…1 each
    var total: Double { user + system }
}

struct MemoryReading {
    var used: UInt64
    var total: UInt64
    var compressed: UInt64
    var wired: UInt64
    var swapUsed: UInt64
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure: Int
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

/// Bytes per second in two directions (network in/out, disk read/write).
struct IORate {
    var a: Double
    var b: Double
}

struct DiskReading {
    var rate: IORate?
    var free: UInt64?
    var capacity: UInt64?
}

struct GPUReading {
    var utilization: Double  // 0…1
    var memoryInUse: UInt64?
}

struct SessionsReading {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let cpu: Double        // percent of one core, like Activity Monitor
        let memory: UInt64     // phys_footprint sum
        let processes: Int
    }
    var rows: [Row]
    /// AgentDeck itself plus every process it started.
    var totalCPU: Double
    var totalMemory: UInt64
    var totalProcesses: Int
    /// The app process alone (renderer, UI).
    var appCPU: Double
    var appMemory: UInt64
    /// False on the first tick: CPU needs two samples.
    var hasCPU: Bool
}

/// What the main thread hands the sampler for the 会话 monitor: each
/// session's name and the foreground pids of its panes' ptys.
struct SessionProbe {
    let id: UUID
    let name: String
    let foregroundPIDs: [pid_t]
}

/// Reads system counters. Owns the previous sample so it can turn
/// cumulative counters into rates. Only ever used on PerformanceMonitor's
/// serial queue, hence the unchecked Sendable.
final class SystemSampler: @unchecked Sendable {
    private var lastTime: UInt64 = 0
    private var lastCPUTicks: [[UInt32]]?
    private var lastNet: (UInt64, UInt64, UInt64)?   // in, out, time
    private var lastDisk: (UInt64, UInt64, UInt64)?  // read, write, time
    private var lastProcCPU: [pid_t: UInt64] = [:]   // ns of CPU time
    private var lastProcTime: UInt64 = 0
    private var diskSpace: (free: UInt64, capacity: UInt64)?
    private var diskSpaceAge = 0

    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Forget previous samples (monitor turned off or panel closed), so the
    /// next rate isn't averaged over the gap.
    func reset(_ kinds: Set<MonitorKind>) {
        if kinds.contains(.cpu) { lastCPUTicks = nil }
        if kinds.contains(.network) { lastNet = nil }
        if kinds.contains(.disk) { lastDisk = nil; diskSpace = nil; diskSpaceAge = 0 }
        if kinds.contains(.sessions) { lastProcCPU = [:]; lastProcTime = 0 }
    }

    func sample(_ kinds: Set<MonitorKind>, sessions: [SessionProbe]) -> PerfReadings {
        reset(Set(MonitorKind.allCases).subtracting(kinds))
        var r = PerfReadings()
        if kinds.contains(.cpu) { r.cpu = sampleCPU() }
        if kinds.contains(.memory) { r.memory = sampleMemory() }
        if kinds.contains(.network) { r.network = sampleNetwork() }
        if kinds.contains(.disk) { r.disk = sampleDisk() }
        if kinds.contains(.gpu) { r.gpu = sampleGPU() }
        if kinds.contains(.sessions) { r.sessions = sampleSessions(sessions) }
        return r
    }

    private func nowNanos() -> UInt64 {
        mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    // MARK: CPU

    private func sampleCPU() -> CPUReading? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for core in 0..<Int(count) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[core * states + $0]) })
        }
        defer { lastCPUTicks = ticks }
        guard let prev = lastCPUTicks, prev.count == ticks.count else { return nil }

        var user = 0.0, system = 0.0, all = 0.0
        var perCore: [Double] = []
        for (now, before) in zip(ticks, prev) {
            // Counters are 32-bit and wrap; &- gives the right delta across a wrap.
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let u = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let s = d[Int(CPU_STATE_SYSTEM)]
            let total = d.reduce(0, +)
            user += u; system += s; all += total
            perCore.append(total > 0 ? (u + s) / total : 0)
        }
        guard all > 0 else { return nil }
        return CPUReading(user: user / all, system: system / all, perCore: perCore)
    }

    // MARK: Memory

    private func sampleMemory() -> MemoryReading? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressure: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pSize, nil, 0)

        return MemoryReading(used: app * page + wired + compressed,
                             total: ProcessInfo.processInfo.physicalMemory,
                             compressed: compressed, wired: wired,
                             swapUsed: swap.xsu_used, pressure: Int(pressure))
    }

    // MARK: Network

    private func sampleNetwork() -> IORate? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        // Physical links only: loopback and tunnels (VPN) would double count.
                        if n.hasPrefix("en") || n.hasPrefix("pdp_ip") {
                            inBytes += m.ifm_data.ifi_ibytes
                            outBytes += m.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        let now = nowNanos()
        defer { lastNet = (inBytes, outBytes, now) }
        guard let (pi, po, pt) = lastNet, now > pt else { return nil }
        let secs = Double(now - pt) / 1e9
        return IORate(a: Double(inBytes &- pi) / secs, b: Double(outBytes &- po) / secs)
    }

    // MARK: Disk

    private func sampleDisk() -> DiskReading {
        var read: UInt64 = 0, write: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            var entry = IOIteratorNext(iter)
            while entry != 0 {
                if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        let now = nowNanos()
        var rate: IORate?
        if let (pr, pw, pt) = lastDisk, now > pt {
            let secs = Double(now - pt) / 1e9
            rate = IORate(a: Double(read &- pr) / secs, b: Double(write &- pw) / secs)
        }
        lastDisk = (read, write, now)

        // Free space barely moves; asking for it every tick is wasted work.
        if diskSpace == nil || diskSpaceAge >= 10 {
            diskSpaceAge = 0
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
               let free = v.volumeAvailableCapacityForImportantUsage, let cap = v.volumeTotalCapacity {
                diskSpace = (UInt64(max(free, 0)), UInt64(max(cap, 0)))
            }
        }
        diskSpaceAge += 1
        return DiskReading(rate: rate, free: diskSpace?.free, capacity: diskSpace?.capacity)
    }

    // MARK: GPU

    private func sampleGPU() -> GPUReading? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var best: GPUReading?
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                let mem = (stats["In use system memory"] as? NSNumber)?.uint64Value
                if best == nil || util / 100 > best!.utilization {
                    best = GPUReading(utilization: min(util / 100, 1), memoryInUse: mem)
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return best
    }

    // MARK: Sessions (AgentDeck's process tree)

    private func sampleSessions(_ probes: [SessionProbe]) -> SessionsReading {
        let me = getpid()
        // pid → parent for every process on the system.
        var parent: [pid_t: pid_t] = [:]
        let n = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(max(n, 0)) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var info = proc_bsdshortinfo()
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 {
                parent[pid] = pid_t(info.pbsi_ppid)
            }
        }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, pp) in parent { children[pp, default: []].append(pid) }

        func subtree(_ root: pid_t) -> [pid_t] {
            var out: [pid_t] = [], stack = [root]
            while let p = stack.popLast() {
                out.append(p)
                stack.append(contentsOf: children[p] ?? [])
            }
            return out
        }

        let tree = subtree(me)
        let now = nowNanos()
        let elapsed = lastProcTime > 0 && now > lastProcTime ? Double(now - lastProcTime) : 0
        var cpuNow: [pid_t: UInt64] = [:]
        var cpu: [pid_t: Double] = [:]
        var mem: [pid_t: UInt64] = [:]
        for pid in tree {
            var ri = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            // ri_*_time is in mach absolute time units.
            let t = (ri.ri_user_time + ri.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            cpuNow[pid] = t
            mem[pid] = ri.ri_phys_footprint
            if elapsed > 0, let before = lastProcCPU[pid], t >= before {
                cpu[pid] = Double(t - before) / elapsed * 100
            }
        }
        lastProcCPU = cpuNow
        lastProcTime = now

        // A pane's foreground pid is the agent (or the shell at its prompt).
        // Climb to the direct child of AgentDeck (login/ssh) so the shell,
        // the agent and everything they spawned all count.
        func sessionRoot(_ pid: pid_t) -> pid_t? {
            var p = pid, hops = 0
            while let pp = parent[p], hops < 64 {
                if pp == me { return p }
                if pp <= 1 { return nil }
                p = pp; hops += 1
            }
            return nil
        }

        var rows: [SessionsReading.Row] = []
        for probe in probes {
            let roots = Set(probe.foregroundPIDs.compactMap(sessionRoot))
            let procs = Set(roots.flatMap(subtree))
            guard !procs.isEmpty else { continue }
            rows.append(.init(id: probe.id, name: probe.name,
                              cpu: procs.reduce(0) { $0 + (cpu[$1] ?? 0) },
                              memory: procs.reduce(0) { $0 + (mem[$1] ?? 0) },
                              processes: procs.count))
        }
        rows.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }

        return SessionsReading(rows: rows,
                               totalCPU: cpu.values.reduce(0, +),
                               totalMemory: mem.values.reduce(0, +),
                               totalProcesses: tree.count,
                               appCPU: cpu[me] ?? 0,
                               appMemory: mem[me] ?? 0,
                               hasCPU: elapsed > 0)
    }
}
