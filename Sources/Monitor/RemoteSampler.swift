import Foundation

/// Whose numbers the 性能 panel shows: this Mac, or the server behind the
/// selected session.
enum MonitorTarget: Equatable {
    case local
    case remote(RemoteHost)

    var host: RemoteHost? {
        if case .remote(let h) = self { return h }
        return nil
    }

    static func == (a: MonitorTarget, b: MonitorTarget) -> Bool {
        switch (a, b) {
        case (.local, .local): true
        // Same server with the same connection settings.
        case (.remote(let x), .remote(let y)): x == y
        default: false
        }
    }
}

struct DockerReading {
    struct Container: Identifiable {
        let id: String
        let name: String
        let image: String
        /// running, exited, paused, restarting, created, dead
        let state: String
        /// e.g. "Up 3 hours", "Exited (0) 2 days ago"
        let status: String
        var cpu: Double?       // percent of one core
        var memory: String?    // docker's own "12.3MiB / 1.9GiB"

        var isRunning: Bool { state == "running" }
    }

    var installed = true
    /// Anything docker printed that isn't a container line (no permission,
    /// daemon not running…).
    var error: String?
    var containers: [Container] = []

    var runningCount: Int { containers.filter(\.isRunning).count }
}

/// The shell loop that does the sampling on the other end. One ssh
/// connection stays open while the panel is; every tick the server prints a
/// block of tagged lines ending in `@end`. Plain POSIX sh plus /proc, so
/// nothing has to be installed. Sent on stdin (`sh -s`), so the user's login
/// shell (fish, zsh…) never has to parse it.
enum MonitorScript {
    static func build(kinds: Set<MonitorKind>, interval: Double, system: Bool) -> String {
        let docker = kinds.contains(.docker)
        let procs = kinds.contains(.sessions)
        let gpu = kinds.contains(.gpu)
        var s = """
        export LC_ALL=C
        P=$$
        T=$(mktemp -d 2>/dev/null) || { T=/tmp/agentdeck-mon.$$; mkdir -p "$T"; }
        trap 'rm -rf "$T"' EXIT
        trap 'rm -rf "$T"; exit 0' HUP INT TERM PIPE
        docker_loop() {
          # Stops by itself once the sampler is gone (connection dropped).
          while kill -0 $P 2>/dev/null; do
            if command -v docker >/dev/null 2>&1; then
              docker ps -a --format "@dp {{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}" >"$T/d.new" 2>&1
              docker stats --no-stream --format "@ds {{.ID}}|{{.CPUPerc}}|{{.MemUsage}}" >>"$T/d.new" 2>/dev/null
            else
              echo @dnone >"$T/d.new"
            fi
            mv -f "$T/d.new" "$T/d"
            sleep 3
          done
        }
        main() {

        """
        if system {
            s += """
              [ -r /proc/stat ] || { echo "@err 目前只支持 Linux 服务器"; exit 1; }
              echo "@hz $(getconf CLK_TCK 2>/dev/null || echo 100) $(getconf PAGESIZE 2>/dev/null || echo 4096)"
              G=; command -v nvidia-smi >/dev/null 2>&1 && G=1

            """
        }
        if docker { s += "  docker_loop &\n" }
        s += "  while :; do\n"
        if system {
            s += """
                echo "@u $(cut -d" " -f1 /proc/uptime)"
                grep "^cpu" /proc/stat | sed "s/^/@s /"
                echo "@l $(cut -d" " -f1-3 /proc/loadavg)"
                grep -E "^(MemTotal|MemAvailable|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):" /proc/meminfo | sed "s/^/@m /"
                sed -n "3,\\$p" /proc/net/dev | sed "s/^/@n /"
                sed "s/^/@k /" /proc/diskstats
                df -Pk / 2>/dev/null | sed -n "2s/^/@f /p"

            """
            if gpu {
                s += """
                    [ -n "$G" ] && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,name --format=csv,noheader,nounits 2>/dev/null | sed "s/^/@g /"

                """
            }
            if procs {
                // pid, comm (spaces → \001), utime, stime, rss pages. comm can
                // contain spaces, so find the field that closes the paren.
                s += """
                    cat /proc/[0-9]*/stat 2>/dev/null | awk '{ n=2; while (n < NF && $n !~ /\\)$/) n++; c=$2; for (i=3; i<=n; i++) c=c "\\001" $i; print "@q", $1, c, $(n+12), $(n+13), $(n+22) }'

                """
            }
        }
        if docker {
            s += """
                if [ -f "$T/d" ]; then mv -f "$T/d" "$T/d.out"; echo @dbegin; cat "$T/d.out"; fi

            """
        }
        s += """
            echo @end || exit 0
            sleep \(Int(max(interval, 1)))
          done
        }
        main </dev/null

        """
        return s
    }
}

/// Runs a sampling script (over ssh, or locally for Docker on this Mac) and
/// hands back each `@end`-terminated block. Callbacks arrive on `queue`.
final class ScriptStream: @unchecked Sendable {
    private let process: Process
    private let script: String
    private let queue: DispatchQueue
    private var buffer = Data()
    private var block: [String] = []
    private var stderrTail = ""
    private var stopped = false
    var onBlock: (([String]) -> Void)?
    /// Exited on its own (connection lost, auth failed…), with stderr's tail.
    var onExit: ((String) -> Void)?

    init(process: Process, script: String, queue: DispatchQueue) {
        self.process = process
        self.script = script
        self.queue = queue
    }

    static func remote(_ host: RemoteHost, script: String, queue: DispatchQueue) -> ScriptStream {
        ScriptStream(process: SSH.backgroundProcess(host, command: "sh -s"), script: script, queue: queue)
    }

    /// Through the login shell, so Docker Desktop / OrbStack / Homebrew's
    /// docker is on PATH.
    static func local(script: String, queue: DispatchQueue) -> ScriptStream {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", "exec /bin/sh -s"]
        return ScriptStream(process: p, script: script, queue: queue)
    }

    func start() {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            self?.queue.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(600))
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                guard let self, !self.stopped else { return }
                self.onExit?(self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do {
            try process.run()
        } catch {
            queue.async { self.onExit?(error.localizedDescription) }
            return
        }
        // Close stdin after the script so commands inside it read EOF.
        let script = Data(script.utf8)
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: script)
            try? input.fileHandleForWriting.close()
        }
    }

    func stop() {
        queue.async { self.stopped = true }
        stopped = true
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line == "@end" {
                let b = block
                block = []
                if !stopped { onBlock?(b) }
            } else {
                block.append(line)
                if block.count > 20000 { block.removeFirst(block.count - 20000) }
            }
        }
    }
}

/// Turns the script's blocks into readings. Keeps the previous counters to
/// compute rates. Use from one queue.
final class RemoteParser {
    private var hz = 100.0
    private var pageSize: UInt64 = 4096
    private var lastUptime: Double?
    private var lastCPU: [String: [UInt64]] = [:]
    private var lastNet: (UInt64, UInt64)?
    private var lastDisk: (UInt64, UInt64)?
    private var lastProc: [Int: UInt64] = [:]

    private static let wholeDisk = try! NSRegularExpression(
        pattern: #"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$"#)
    /// Virtual links that would count container / VPN traffic twice.
    private static let virtualLink = ["lo", "veth", "docker", "br-", "virbr", "cni", "flannel", "cali",
                                      "tun", "tap", "wg", "tailscale", "zt", "kube", "vxlan", "weave"]

    /// docker's own errors are long and technical; lead with what it means.
    private static func explain(_ error: String) -> String {
        let e = error.lowercased()
        if e.contains("permission denied") {
            return "没有权限访问 Docker（需要把用户加入 docker 组）\n\n" + error
        }
        if e.contains("daemon") || e.contains("docker api") || e.contains("docker.sock") || e.contains("cannot connect") {
            return "Docker 没有在运行\n\n" + error
        }
        return error
    }

    /// Error text from an `@err` line, if the server can't be sampled.
    private(set) var fatal: String?

    func parse(_ lines: [String], kinds: Set<MonitorKind>) -> PerfReadings {
        var uptime: Double?
        var cpuLines: [(String, [UInt64])] = []
        var load: [Double]?
        var mem: [String: UInt64] = [:]
        var netIn: UInt64 = 0, netOut: UInt64 = 0, sawNet = false
        var diskR: UInt64 = 0, diskW: UInt64 = 0, sawDisk = false
        var df: (UInt64, UInt64)?
        var gpus: [GPUReading] = []
        var procs: [(pid: Int, name: String, ticks: UInt64, rss: UInt64)] = []
        var docker: DockerReading?
        var dockerStats: [String: (Double?, String)] = [:]
        var inDocker = false
        var dockerErrors: [String] = []

        for line in lines {
            if inDocker {
                if line.hasPrefix("@dp ") {
                    let f = line.dropFirst(4).split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                    if f.count == 5 {
                        docker?.containers.append(.init(id: f[0], name: f[1], image: f[2], state: f[3], status: f[4]))
                    }
                    continue
                } else if line.hasPrefix("@ds ") {
                    let f = line.dropFirst(4).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    if f.count == 3 {
                        dockerStats[f[0]] = (Double(f[1].replacingOccurrences(of: "%", with: "")), f[2])
                    }
                    continue
                } else if line == "@dnone" {
                    docker?.installed = false
                    continue
                } else if !line.hasPrefix("@") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { dockerErrors.append(t) }
                    continue
                }
                inDocker = false
            }
            guard line.hasPrefix("@") else { continue }
            let tag = line.prefix { $0 != " " }
            let rest = line.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
            let f = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch tag {
            case "@err": fatal = rest
            case "@hz":
                if f.count >= 2 { hz = Double(f[0]) ?? 100; pageSize = UInt64(f[1]) ?? 4096 }
            case "@u": uptime = Double(rest)
            case "@s":
                if f.count >= 5 { cpuLines.append((f[0], f.dropFirst().compactMap { UInt64($0) })) }
            case "@l": load = f.compactMap(Double.init)
            case "@m":
                if f.count >= 2 { mem[f[0].trimmingCharacters(in: CharacterSet(charactersIn: ":"))] = (UInt64(f[1]) ?? 0) * 1024 }
            case "@n":
                let parts = rest.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { break }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                if Self.virtualLink.contains(where: { name.hasPrefix($0) }) { break }
                let v = parts[1].split(separator: " ").compactMap { UInt64($0) }
                if v.count >= 9 { netIn &+= v[0]; netOut &+= v[8]; sawNet = true }
            case "@k":
                // major minor name reads merged sectorsRead ms writes merged sectorsWritten …
                guard f.count >= 10 else { break }
                let name = f[2]
                guard Self.wholeDisk.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { break }
                diskR &+= (UInt64(f[5]) ?? 0) * 512
                diskW &+= (UInt64(f[9]) ?? 0) * 512
                sawDisk = true
            case "@f":
                // Filesystem 1024-blocks Used Available Capacity Mounted
                if f.count >= 4, let size = UInt64(f[1]), let avail = UInt64(f[3]) { df = (avail * 1024, size * 1024) }
            case "@g":
                let g = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if g.count >= 3, let u = Double(g[0]) {
                    gpus.append(GPUReading(utilization: min(u / 100, 1),
                                           memoryInUse: UInt64(g[1]).map { $0 * 1_048_576 },
                                           memoryTotal: UInt64(g[2]).map { $0 * 1_048_576 },
                                           name: g.count > 3 ? g[3] : nil))
                }
            case "@q":
                if f.count >= 5, let pid = Int(f[0]), let u = UInt64(f[2]), let s = UInt64(f[3]), let rss = UInt64(f[4]) {
                    var name = f[1]
                    if name.hasPrefix("(") { name.removeFirst() }
                    if name.hasSuffix(")") { name.removeLast() }
                    procs.append((pid, name.replacingOccurrences(of: "\u{01}", with: " "), u + s, rss * pageSize))
                }
            case "@dbegin":
                inDocker = true
                docker = DockerReading()
            default: break
            }
        }

        var r = PerfReadings()
        let elapsed: Double? = {
            guard let uptime, let last = lastUptime, uptime > last else { return nil }
            return uptime - last
        }()
        if let uptime { lastUptime = uptime }

        if kinds.contains(.cpu), !cpuLines.isEmpty {
            var reading: CPUReading?
            func usage(_ name: String, _ now: [UInt64]) -> (Double, Double)? {
                defer { lastCPU[name] = now }
                guard let before = lastCPU[name], before.count == now.count, now.count >= 4 else { return nil }
                let d = zip(now, before).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                guard total > 0 else { return nil }
                // user nice system idle iowait irq softirq steal …
                let user = d[0] + d[1]
                let system = d[2] + (d.count > 6 ? d[5] + d[6] : 0)
                return (user / total, system / total)
            }
            var perCore: [Double] = []
            for (name, v) in cpuLines {
                guard let (u, s) = usage(name, v) else { continue }
                if name == "cpu" { reading = CPUReading(user: u, system: s, perCore: []) }
                else { perCore.append(u + s) }
            }
            reading?.perCore = perCore
            reading?.load = load
            r.cpu = reading
        }

        if kinds.contains(.memory), let total = mem["MemTotal"], total > 0 {
            let avail = mem["MemAvailable"] ?? 0
            let cache = (mem["Buffers"] ?? 0) + (mem["Cached"] ?? 0) + (mem["SReclaimable"] ?? 0)
            let swap = (mem["SwapTotal"] ?? 0) - min(mem["SwapTotal"] ?? 0, mem["SwapFree"] ?? 0)
            let freeFraction = Double(avail) / Double(total)
            r.memory = MemoryReading(used: total - min(avail, total), total: total,
                                     extras: [("缓存", cache)], swapUsed: swap,
                                     pressure: freeFraction < 0.05 ? 4 : freeFraction < 0.15 ? 2 : 1)
        }

        if kinds.contains(.network), sawNet {
            if let (pi, po) = lastNet, let elapsed {
                r.network = IORate(a: Double(netIn &- pi) / elapsed, b: Double(netOut &- po) / elapsed)
            }
            lastNet = (netIn, netOut)
        }

        if kinds.contains(.disk), sawDisk || df != nil {
            var d = DiskReading(free: df?.0, capacity: df?.1)
            if let (pr, pw) = lastDisk, let elapsed {
                d.rate = IORate(a: Double(diskR &- pr) / elapsed, b: Double(diskW &- pw) / elapsed)
            }
            lastDisk = (diskR, diskW)
            r.disk = d
        }

        if kinds.contains(.gpu) {
            r.gpu = gpus.max { $0.utilization < $1.utilization }
        }

        if kinds.contains(.sessions), !procs.isEmpty {
            var now: [Int: UInt64] = [:]
            var top: [TopProcess] = []
            for p in procs {
                now[p.pid] = p.ticks
                if let elapsed, let before = lastProc[p.pid], p.ticks >= before {
                    top.append(TopProcess(id: p.pid, name: p.name,
                                          cpu: Double(p.ticks - before) / hz / elapsed * 100, memory: p.rss))
                }
            }
            lastProc = now
            if elapsed != nil {
                top.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
                r.processes = Array(top.prefix(6))
            }
        }

        if var docker {
            for i in docker.containers.indices {
                if let (cpu, mem) = dockerStats[docker.containers[i].id] {
                    docker.containers[i].cpu = cpu
                    docker.containers[i].memory = mem
                }
            }
            if !dockerErrors.isEmpty { docker.error = Self.explain(dockerErrors.prefix(3).joined(separator: "\n")) }
            r.docker = docker
        }
        return r
    }
}

/// Container actions, on this Mac or over ssh.
enum DockerControl {
    static func run(_ args: [String], on target: MonitorTarget) async -> SSH.ProbeResult {
        let command = "docker " + args.map(SSH.quote).joined(separator: " ")
        if let host = target.host { return await SSH.run(host, command: command, timeout: 60) }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            p.arguments = ["-l", "-c", command]
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: .init(ok: proc.terminationStatus == 0, output: String(decoding: data, as: UTF8.self)))
            }
            do { try p.run() } catch {
                cont.resume(returning: .init(ok: false, output: error.localizedDescription))
            }
        }
    }

    /// Prefer bash inside the container, fall back to sh.
    static func shellCommand(_ id: String) -> String {
        "docker exec -it \(SSH.quote(id)) sh -c " + SSH.quote("command -v bash >/dev/null 2>&1 && exec bash || exec sh")
    }

    static func logsCommand(_ id: String) -> String {
        "docker logs -f --tail 200 \(SSH.quote(id))"
    }
}
