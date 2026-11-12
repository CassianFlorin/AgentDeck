import SwiftUI

/// The 性能 panel: the right-hand inspector with one card per switched-on
/// monitor. Sampling starts when the panel appears and stops when it goes
/// away, so a closed panel costs nothing.
struct MonitorPanel: View {
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @EnvironmentObject private var workspace: Workspace
    @AppStorage(MonitorSettings.kindsKey) private var kindsRaw = MonitorSettings.defaultKinds
    @AppStorage(MonitorSettings.intervalKey) private var interval = MonitorSettings.defaultInterval

    private var kinds: Set<MonitorKind> { MonitorSettings.decode(kindsRaw) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if kinds.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(MonitorKind.allCases.filter(kinds.contains)) { kind in
                            card(kind)
                                .contextMenu {
                                    Button("隐藏\(kind.title)") { set(kind, on: false) }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .onAppear {
            monitor.workspace = workspace
            monitor.start(kinds: kinds, interval: interval)
        }
        .onDisappear { monitor.stop() }
        .onChange(of: kindsRaw) { _, _ in monitor.update(kinds: kinds, interval: interval) }
        .onChange(of: interval) { _, _ in monitor.update(kinds: kinds, interval: interval) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("性能").font(.headline)
            Spacer()
            Menu {
                Section("显示") {
                    ForEach(MonitorKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { kinds.contains(kind) }, set: { set(kind, on: $0) })) {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                }
                Section("刷新间隔") {
                    Picker("刷新间隔", selection: $interval) {
                        ForEach(MonitorSettings.intervals, id: \.self) { s in
                            Text("\(Int(s)) 秒").tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择要显示的监视器")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有打开的监视器").foregroundStyle(.secondary)
            Button("显示 CPU 和内存") { kindsRaw = MonitorSettings.defaultKinds }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func set(_ kind: MonitorKind, on: Bool) {
        var k = kinds
        if on { k.insert(kind) } else { k.remove(kind) }
        kindsRaw = MonitorSettings.encode(k)
    }

    @ViewBuilder
    private func card(_ kind: MonitorKind) -> some View {
        let r = monitor.readings
        let h = monitor.history
        switch kind {
        case .cpu: CPUCard(reading: r.cpu, history: h["cpu.total"])
        case .memory: MemoryCard(reading: r.memory, history: h["memory.used"])
        case .gpu: GPUCard(reading: r.gpu, history: h["gpu.util"])
        case .network: NetworkCard(reading: r.network, inHistory: h["network.in"], outHistory: h["network.out"])
        case .disk: DiskCard(reading: r.disk, readHistory: h["disk.read"], writeHistory: h["disk.write"])
        case .sessions: SessionsCard(reading: r.sessions, history: h["sessions.cpu"])
        }
    }
}

// MARK: - Cards

private struct MonitorCard<Content: View>: View {
    let kind: MonitorKind
    let value: String
    var valueColor: Color = .primary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.title, systemImage: kind.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
            content
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

private struct CPUCard: View {
    let reading: CPUReading?
    let history: Series?

    var body: some View {
        MonitorCard(kind: .cpu, value: reading.map { Fmt.percent($0.total) } ?? "—",
                    valueColor: Fmt.loadColor(reading?.total ?? 0)) {
            Sparkline(series: [.init(values: history?.values ?? [], color: .blue)], maxValue: 1)
            if let reading {
                CoreBars(values: reading.perCore)
                HStack {
                    LegendDot(color: .blue, text: "用户 \(Fmt.percent(reading.user))")
                    LegendDot(color: .red, text: "系统 \(Fmt.percent(reading.system))")
                    Spacer()
                    Text("\(reading.perCore.count) 核").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

private struct MemoryCard: View {
    let reading: MemoryReading?
    let history: Series?

    private var pressureColor: Color {
        switch reading?.pressure ?? 1 {
        case 4: .red
        case 2: .yellow
        default: .green
        }
    }

    var body: some View {
        MonitorCard(kind: .memory, value: reading.map { Fmt.percent($0.fraction) } ?? "—") {
            Sparkline(series: [.init(values: history?.values ?? [], color: pressureColor)], maxValue: 1)
            if let r = reading {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("已用 \(Fmt.bytes(r.used)) / \(Fmt.bytes(r.total))")
                        Spacer()
                        LegendDot(color: pressureColor, text: r.pressure >= 4 ? "压力高" : r.pressure >= 2 ? "压力中" : "压力正常")
                    }
                    HStack {
                        Text("联动 \(Fmt.bytes(r.wired))")
                        Text("压缩 \(Fmt.bytes(r.compressed))")
                        Spacer()
                        if r.swapUsed > 0 { Text("交换 \(Fmt.bytes(r.swapUsed))") }
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
    }
}

private struct GPUCard: View {
    let reading: GPUReading?
    let history: Series?

    var body: some View {
        MonitorCard(kind: .gpu, value: reading.map { Fmt.percent($0.utilization) } ?? "—",
                    valueColor: Fmt.loadColor(reading?.utilization ?? 0)) {
            Sparkline(series: [.init(values: history?.values ?? [], color: .purple)], maxValue: 1)
            if let mem = reading?.memoryInUse {
                Text("显存占用 \(Fmt.bytes(mem))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct NetworkCard: View {
    let reading: IORate?
    let inHistory: Series?
    let outHistory: Series?

    var body: some View {
        MonitorCard(kind: .network, value: reading.map { Fmt.rate($0.a + $0.b) } ?? "—") {
            Sparkline(series: [.init(values: inHistory?.values ?? [], color: .green),
                               .init(values: outHistory?.values ?? [], color: .orange)],
                      maxValue: nil)
            HStack {
                LegendDot(color: .green, text: "↓ \(reading.map { Fmt.rate($0.a) } ?? "—")")
                Spacer()
                LegendDot(color: .orange, text: "↑ \(reading.map { Fmt.rate($0.b) } ?? "—")")
            }
            .font(.caption).monospacedDigit()
        }
    }
}

private struct DiskCard: View {
    let reading: DiskReading?
    let readHistory: Series?
    let writeHistory: Series?

    var body: some View {
        MonitorCard(kind: .disk, value: reading?.rate.map { Fmt.rate($0.a + $0.b) } ?? "—") {
            Sparkline(series: [.init(values: readHistory?.values ?? [], color: .teal),
                               .init(values: writeHistory?.values ?? [], color: .pink)],
                      maxValue: nil)
            HStack {
                LegendDot(color: .teal, text: "读 \(reading?.rate.map { Fmt.rate($0.a) } ?? "—")")
                Spacer()
                LegendDot(color: .pink, text: "写 \(reading?.rate.map { Fmt.rate($0.b) } ?? "—")")
            }
            .font(.caption).monospacedDigit()
            if let free = reading?.free, let cap = reading?.capacity, cap > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(cap - min(free, cap)), total: Double(cap))
                        .tint(Double(free) / Double(cap) < 0.1 ? .red : .accentColor)
                    Text("可用 \(Fmt.bytes(free)) / \(Fmt.bytes(cap))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

private struct SessionsCard: View {
    let reading: SessionsReading?
    let history: Series?

    var body: some View {
        MonitorCard(kind: .sessions,
                    value: reading.flatMap { $0.hasCPU ? Fmt.cpu($0.totalCPU) : nil } ?? "—") {
            Sparkline(series: [.init(values: history?.values ?? [], color: .cyan)], maxValue: nil, floor: 100)
            if let r = reading {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("AgentDeck 共 \(r.totalProcesses) 个进程")
                        Spacer()
                        Text(Fmt.bytes(r.totalMemory))
                    }
                    .foregroundStyle(.secondary)
                    Divider().opacity(0.5)
                    row(name: "AgentDeck 本身", cpu: r.hasCPU ? r.appCPU : nil, memory: r.appMemory, detail: nil)
                    ForEach(r.rows) { s in
                        row(name: s.name, cpu: r.hasCPU ? s.cpu : nil, memory: s.memory,
                            detail: s.processes > 1 ? "\(s.processes) 个进程" : nil)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .help("CPU 以单核为 100%，和活动监视器一致")
    }

    private func row(name: String, cpu: Double?, memory: UInt64, detail: String?) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1).truncationMode(.tail)
                if let detail { Text(detail).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 4)
            Text(cpu.map(Fmt.cpu) ?? "—")
                .foregroundStyle(Fmt.loadColor((cpu ?? 0) / 100))
                .frame(minWidth: 44, alignment: .trailing)
            Text(Fmt.bytes(memory))
                .foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)
        }
    }
}

// MARK: - Drawing

/// Line + soft fill for up to a few series sharing one scale. Drawn with a
/// Canvas: much lighter than Swift Charts for something redrawn every second.
private struct Sparkline: View {
    struct Line {
        let values: [Double]
        let color: Color
    }

    let series: [Line]
    /// Fixed top of the scale (1 for fractions); nil scales to the data.
    let maxValue: Double?
    /// Smallest top when auto-scaling, so idle noise doesn't fill the chart.
    var floor: Double = 1024

    var body: some View {
        Canvas { ctx, size in
            let top = maxValue ?? max(series.flatMap(\.values).max() ?? 0, floor) * 1.15
            guard top > 0 else { return }
            // Faint mid line for scale.
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: size.height / 2))
            grid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(grid, with: .color(.white.opacity(0.06)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            let step = size.width / CGFloat(Series.capacity - 1)
            for line in series where line.values.count > 1 {
                // Newest sample sits at the right edge.
                let start = CGFloat(Series.capacity - line.values.count) * step
                let points = line.values.enumerated().map { i, v in
                    CGPoint(x: start + CGFloat(i) * step,
                            y: size.height - CGFloat(min(v / top, 1)) * (size.height - 1))
                }
                var stroke = Path()
                stroke.addLines(points)
                var fill = stroke
                fill.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                fill.addLine(to: CGPoint(x: points.first!.x, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [line.color.opacity(0.35), line.color.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(stroke, with: .color(line.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: 44)
        .accessibilityHidden(true)
    }
}

/// One bar per core. A Canvas with no animation: an animated SwiftUI bar per
/// core re-rendered every frame of each transition and cost ~10% CPU.
private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (w + gap)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: 1.5),
                         with: .color(.white.opacity(0.06)))
                let h = max(2, size.height * CGFloat(min(max(v, 0), 1)))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: w, height: h), cornerRadius: 1.5),
                         with: .color(Fmt.loadColor(v).opacity(0.85)))
            }
        }
        .frame(height: 18)
        .help("每个核心的占用")
        .accessibilityHidden(true)
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

enum Fmt {
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    /// Percent of one core, e.g. "135%".
    static func cpu(_ p: Double) -> String { p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%" }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }

    static func rate(_ bps: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(bps, 0), i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[i])" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    static func loadColor(_ f: Double) -> Color {
        f >= 0.85 ? .red : f >= 0.6 ? .orange : f >= 0.3 ? .yellow : .green
    }
}
