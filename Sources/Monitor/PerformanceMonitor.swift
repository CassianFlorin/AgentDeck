import AppKit
import Combine
import GhosttyKit

/// One card in the 性能 panel.
enum MonitorKind: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, disk, sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "内存"
        case .gpu: "GPU"
        case .network: "网络"
        case .disk: "磁盘"
        case .sessions: "会话占用"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .network: "network"
        case .disk: "internaldrive"
        case .sessions: "terminal"
        }
    }
}

/// Settings for the 性能 panel (the right-hand inspector).
enum MonitorSettings {
    /// Whether the panel is open. Off by default; sampling only runs while it is.
    static let visibleKey = "monitor.visible"
    /// Comma-separated `MonitorKind` raw values that are switched on.
    static let kindsKey = "monitor.kinds"
    static let intervalKey = "monitor.interval"
    static let defaultKinds = "cpu,memory"
    static let defaultInterval = 1.0
    static let intervals: [Double] = [1, 2, 5]

    static func decode(_ raw: String) -> Set<MonitorKind> {
        Set(raw.split(separator: ",").compactMap { MonitorKind(rawValue: String($0)) })
    }

    static func encode(_ kinds: Set<MonitorKind>) -> String {
        MonitorKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// Fixed-length history for a sparkline.
struct Series {
    static let capacity = 60
    private(set) var values: [Double] = []

    mutating func append(_ v: Double?) {
        guard let v else { return }
        values.append(v)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }
}

/// Samples the switched-on monitors while the panel is open. `start()` /
/// `stop()` follow the panel, so with it closed nothing is read at all.
@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published private(set) var readings = PerfReadings()
    @Published private(set) var history: [String: Series] = [:]

    private(set) var isRunning = false
    private var kinds: Set<MonitorKind> = []
    private var interval = MonitorSettings.defaultInterval
    private var timer: Timer?
    private var inFlight = false
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "agentdeck.monitor", qos: .utility)
    weak var workspace: Workspace?

    func start(kinds: Set<MonitorKind>, interval: Double) {
        self.kinds = kinds
        self.interval = interval
        isRunning = true
        reschedule()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        readings = PerfReadings()
        history = [:]
        queue.async { [sampler] in sampler.reset(Set(MonitorKind.allCases)) }
    }

    func update(kinds: Set<MonitorKind>, interval: Double) {
        guard isRunning else { return }
        for gone in self.kinds.subtracting(kinds) { clear(gone) }
        let intervalChanged = interval != self.interval
        self.kinds = kinds
        self.interval = interval
        if intervalChanged { reschedule() } else if timer == nil { reschedule() }
    }

    private func clear(_ kind: MonitorKind) {
        history = history.filter { !$0.key.hasPrefix(kind.rawValue + ".") }
        switch kind {
        case .cpu: readings.cpu = nil
        case .memory: readings.memory = nil
        case .network: readings.network = nil
        case .disk: readings.disk = nil
        case .gpu: readings.gpu = nil
        case .sessions: readings.sessions = nil
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isRunning, !kinds.isEmpty else { return }
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Window hidden behind other windows or minimised: nobody is looking.
        guard isRunning, !inFlight, NSApp.occlusionState.contains(.visible) else { return }
        let kinds = self.kinds
        guard !kinds.isEmpty else { return }
        let probes = kinds.contains(.sessions) ? sessionProbes() : []
        inFlight = true
        queue.async { [sampler] in
            let r = sampler.sample(kinds, sessions: probes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.publish(r, kinds: kinds) }
            }
        }
    }

    private func publish(_ r: PerfReadings, kinds sampled: Set<MonitorKind>) {
        inFlight = false
        guard isRunning else { return }
        // Drop readings for monitors switched off while this tick was in flight.
        let live = sampled.intersection(kinds)
        var h = history
        if live.contains(.cpu) {
            readings.cpu = r.cpu ?? readings.cpu
            h["cpu.total", default: .init()].append(r.cpu?.total)
        }
        if live.contains(.memory) {
            readings.memory = r.memory
            h["memory.used", default: .init()].append(r.memory?.fraction)
        }
        if live.contains(.gpu) {
            readings.gpu = r.gpu
            h["gpu.util", default: .init()].append(r.gpu?.utilization)
        }
        if live.contains(.network) {
            readings.network = r.network ?? readings.network
            h["network.in", default: .init()].append(r.network?.a)
            h["network.out", default: .init()].append(r.network?.b)
        }
        if live.contains(.disk) {
            readings.disk = r.disk
            h["disk.read", default: .init()].append(r.disk?.rate?.a)
            h["disk.write", default: .init()].append(r.disk?.rate?.b)
        }
        if live.contains(.sessions) {
            readings.sessions = r.sessions
            if r.sessions?.hasCPU == true {
                h["sessions.cpu", default: .init()].append(r.sessions?.totalCPU)
            }
        }
        history = h
    }

    private func sessionProbes() -> [SessionProbe] {
        (workspace?.sessions ?? []).map { session in
            let pids = session.panes.compactMap { pane -> pid_t? in
                guard let s = pane.terminal.surface else { return nil }
                let pid = ghostty_surface_foreground_pid(s)
                return pid > 0 ? pid_t(truncatingIfNeeded: pid) : nil
            }
            return SessionProbe(id: session.id, name: session.displayName, foregroundPIDs: pids)
        }
    }
}
