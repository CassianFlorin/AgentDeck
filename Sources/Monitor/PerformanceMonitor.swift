import AppKit
import Combine
import GhosttyKit

/// One card in the 性能 panel.
enum MonitorKind: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, disk, sessions, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "内存"
        case .gpu: "GPU"
        case .network: "网络"
        case .disk: "磁盘"
        case .sessions: "会话占用"
        case .docker: "Docker"
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
        case .docker: "shippingbox"
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
///
/// For this Mac the counters are read natively on a timer. For a server one
/// ssh connection runs `MonitorScript`, which streams a block per tick;
/// Docker (on either) comes from the same kind of stream.
@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published private(set) var readings = PerfReadings()
    @Published private(set) var history: [String: Series] = [:]
    @Published private(set) var target: MonitorTarget = .local
    /// Why the server can't be sampled right now (connection failed…).
    @Published private(set) var remoteError: String?
    /// Connected and waiting for the first block.
    @Published private(set) var connecting = false

    private(set) var isRunning = false
    private var kinds: Set<MonitorKind> = []
    private var interval = MonitorSettings.defaultInterval
    private var timer: Timer?
    private var inFlight = false
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "agentdeck.monitor", qos: .utility)
    private var stream: ScriptStream?
    private var retry: DispatchWorkItem?
    private var occlusionObserver: NSObjectProtocol?
    /// Bumped on every (re)configuration; late callbacks from an older
    /// stream compare against it and drop themselves.
    private var generation = 0
    weak var workspace: Workspace?

    func start(kinds: Set<MonitorKind>, interval: Double, target: MonitorTarget) {
        self.kinds = kinds
        self.interval = interval
        self.target = target
        isRunning = true
        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reconfigure() } }
        }
        reconfigure()
    }

    func stop() {
        isRunning = false
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = nil
        teardown()
        readings = PerfReadings()
        history = [:]
        remoteError = nil
        connecting = false
    }

    func update(kinds: Set<MonitorKind>, interval: Double, target: MonitorTarget) {
        guard isRunning else { return }
        let targetChanged = target != self.target
        if targetChanged {
            readings = PerfReadings()
            history = [:]
            remoteError = nil
        } else {
            for gone in self.kinds.subtracting(kinds) { clear(gone) }
        }
        guard targetChanged || kinds != self.kinds || interval != self.interval else { return }
        self.kinds = kinds
        self.interval = interval
        self.target = target
        reconfigure()
    }

    private func clear(_ kind: MonitorKind) {
        history = history.filter { !$0.key.hasPrefix(kind.rawValue + ".") }
        switch kind {
        case .cpu: readings.cpu = nil
        case .memory: readings.memory = nil
        case .network: readings.network = nil
        case .disk: readings.disk = nil
        case .gpu: readings.gpu = nil
        case .sessions: readings.sessions = nil; readings.processes = nil
        case .docker: readings.docker = nil
        }
    }

    private func teardown() {
        generation += 1
        timer?.invalidate()
        timer = nil
        retry?.cancel()
        retry = nil
        stream?.stop()
        stream = nil
        inFlight = false
        queue.async { [sampler] in sampler.reset(Set(MonitorKind.allCases)) }
    }

    /// Start whatever the current target and kinds need, from scratch.
    private func reconfigure() {
        teardown()
        // Window minimised or covered: nobody is looking, so read nothing and
        // drop the ssh connection; it comes back when the window does.
        guard isRunning, !kinds.isEmpty, NSApp.occlusionState.contains(.visible) else { return }
        switch target {
        case .local:
            if !kinds.subtracting([.docker]).isEmpty { startTimer() }
            if kinds.contains(.docker) {
                startStream(ScriptStream.local(script: MonitorScript.build(kinds: [.docker], interval: interval, system: false),
                                               queue: queue))
            }
        case .remote(let host):
            connecting = readings.cpu == nil && readings.memory == nil
            startStream(ScriptStream.remote(host, script: MonitorScript.build(kinds: kinds, interval: interval, system: true),
                                            queue: queue))
        }
    }

    private func startTimer() {
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startStream(_ s: ScriptStream) {
        let gen = generation
        let kinds = self.kinds
        let parser = RemoteParser()
        s.onBlock = { [weak self] lines in
            let r = parser.parse(lines, kinds: kinds)
            let fatal = parser.fatal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.connecting = false
                    self.remoteError = fatal
                    self.publish(r, kinds: kinds, fromStream: true)
                }
            }
        }
        s.onExit = { [weak self] message in
            let fatal = parser.fatal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.connecting = false
                    self.stream = nil
                    self.remoteError = fatal ?? (message.isEmpty ? "连接已断开" : message)
                    // Not Linux: retrying won't help. Otherwise try again in a while.
                    if fatal == nil { self.scheduleRetry() }
                }
            }
        }
        stream = s
        s.start()
    }

    private func scheduleRetry() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func tick() {
        guard isRunning, !inFlight else { return }
        let kinds = self.kinds.subtracting([.docker])
        guard !kinds.isEmpty else { return }
        let probes = kinds.contains(.sessions) ? sessionProbes() : []
        let gen = generation
        inFlight = true
        queue.async { [sampler] in
            let r = sampler.sample(kinds, sessions: probes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == gen else { return }
                    self.inFlight = false
                    self.publish(r, kinds: kinds, fromStream: false)
                }
            }
        }
    }

    private func publish(_ r: PerfReadings, kinds sampled: Set<MonitorKind>, fromStream: Bool) {
        guard isRunning else { return }
        // Locally the stream only carries Docker; the timer carries the rest.
        var live = sampled.intersection(kinds)
        if target == .local { live = fromStream ? live.intersection([.docker]) : live.subtracting([.docker]) }
        var h = history
        if live.contains(.cpu) {
            readings.cpu = r.cpu ?? readings.cpu
            h["cpu.total", default: .init()].append(r.cpu?.total)
        }
        if live.contains(.memory) {
            readings.memory = r.memory ?? readings.memory
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
            if let d = r.disk {
                readings.disk = DiskReading(rate: d.rate ?? readings.disk?.rate,
                                            free: d.free ?? readings.disk?.free,
                                            capacity: d.capacity ?? readings.disk?.capacity)
            }
            h["disk.read", default: .init()].append(r.disk?.rate?.a)
            h["disk.write", default: .init()].append(r.disk?.rate?.b)
        }
        if live.contains(.sessions) {
            if target == .local {
                readings.sessions = r.sessions
                if r.sessions?.hasCPU == true {
                    h["sessions.cpu", default: .init()].append(r.sessions?.totalCPU)
                }
            } else if let p = r.processes {
                readings.processes = p
            }
        }
        // Docker refreshes every few seconds; blocks in between carry none.
        if live.contains(.docker), let d = r.docker {
            readings.docker = d
        }
        history = h
    }

    /// Re-read containers soon after an action instead of waiting for the next round.
    func dockerChanged() {
        guard isRunning, kinds.contains(.docker) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Remote streams carry everything, so only restart a local Docker-only stream.
            guard let self, self.target == .local else { return }
            self.reconfigure()
        }
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
