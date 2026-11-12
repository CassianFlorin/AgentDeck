import AppKit
import GhosttyKit
import SwiftUI

/// 设置 → 终端: a visual editor for the most common Ghostty options.
///
/// Nothing here touches the user's own Ghostty config. Every option is
/// "follow Ghostty" (nil) until changed; changed ones are written into the
/// same overlay file as 外观, loaded after ~/.config/ghostty/config, so they
/// win over it and libghostty applies them live to every terminal.
struct TerminalOptions: Codable, Equatable {
    var theme: String?
    var fontFamily: String?
    var fontSize: Double?
    /// `adjust-cell-height`, in percent.
    var cellHeight: Double?
    var fontThicken: Bool?
    /// Font for Chinese/Japanese/Korean text. nil = PingFang SC (AgentDeck's
    /// default), "" = leave it to Ghostty's own fallback.
    var cjkFont: String?
    /// block, bar, underline, block_hollow
    var cursorStyle: String?
    var cursorBlink: Bool?
    var padding: Double?
    /// true, false, left, right
    var optionAsAlt: String?
    var copyOnSelect: Bool?
    var mouseHide: Bool?

    var isEmpty: Bool { self == TerminalOptions() }
}

enum TerminalSettings {
    static let key = "terminal.options"

    static func load() -> TerminalOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              let o = try? JSONDecoder().decode(TerminalOptions.self, from: data) else { return TerminalOptions() }
        return o
    }

    static func save(_ o: TerminalOptions) {
        if o.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(o) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static let defaultCJKFont = "PingFang SC"

    /// CJK punctuation, kana, Hangul, ideographs and fullwidth forms.
    ///
    /// Left to itself Ghostty only asks macOS (locale-aware) for the
    /// ideograph block U+4E00–U+9FFF; everything else, CJK punctuation
    /// included, goes to a generic "monospace fonts first" search that on a
    /// stock Mac lands on Lantinghei TC Demibold. Once loaded, that font is
    /// also reused for every ideograph it happens to contain, so text ends up
    /// a mix of bold Traditional-Chinese glyphs (with centred ，。) and
    /// PingFang SC. Pinning the whole range to one font fixes both.
    static let cjkRanges = [
        "U+2E80-U+2FDF", "U+2FF0-U+2FFF", "U+3000-U+303F", "U+3040-U+30FF",
        "U+3100-U+312F", "U+3130-U+318F", "U+3190-U+31FF", "U+3200-U+33FF",
        "U+3400-U+4DBF", "U+4E00-U+9FFF", "U+AC00-U+D7AF", "U+F900-U+FAFF",
        "U+FE10-U+FE1F", "U+FE30-U+FE4F", "U+FF00-U+FFEF",
        "U+20000-U+2FA1F",
    ].joined(separator: ",")

    /// Ghostty config lines for the options that were changed.
    static var ghosttyOverlay: String {
        let o = load()
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: ""))\"" }
        func b(_ v: Bool) -> String { v ? "true" : "false" }
        var lines: [String] = []
        if let v = o.theme { lines.append("theme = \(q(v))") }
        if let v = o.fontFamily {
            // font-family is repeatable: "" clears the user's list first.
            lines.append("font-family = \"\"")
            lines.append("font-family = \(q(v))")
        }
        if let v = o.fontSize { lines.append("font-size = \(v)") }
        if let v = o.cellHeight { lines.append("adjust-cell-height = \(Int(v))%") }
        if let v = o.fontThicken { lines.append("font-thicken = \(b(v))") }
        let cjk = o.cjkFont ?? defaultCJKFont
        if !cjk.isEmpty { lines.append("font-codepoint-map = \(cjkRanges)=\(cjk.replacingOccurrences(of: "\"", with: ""))") }
        if let v = o.cursorStyle { lines.append("cursor-style = \(v)") }
        if let v = o.cursorBlink { lines.append("cursor-style-blink = \(b(v))") }
        if let v = o.padding {
            lines.append("window-padding-x = \(Int(v))")
            lines.append("window-padding-y = \(Int(v))")
        }
        if let v = o.optionAsAlt { lines.append("macos-option-as-alt = \(v)") }
        if let v = o.copyOnSelect { lines.append("copy-on-select = \(v ? "clipboard" : "false")") }
        if let v = o.mouseHide { lines.append("mouse-hide-while-typing = \(b(v))") }
        guard !lines.isEmpty else { return "" }
        return "# Written by AgentDeck (设置 → 终端). Edits here are overwritten.\n"
            + lines.joined(separator: "\n") + "\n"
    }
}

/// What the user's own Ghostty config says, for the "跟随 Ghostty（…）" labels.
struct GhosttyUserValues {
    var fontSize: Double = 13
    var cursorStyle = "block"
    var cursorBlink: Bool?
    var fontThicken = false
    var mouseHide = false
    var copyOnSelect = false
    var optionAsAlt: String?

    static func read() -> GhosttyUserValues {
        var v = GhosttyUserValues()
        guard let cfg = GhosttyRuntime.userConfig() else { return v }
        defer { ghostty_config_free(cfg) }
        if let f: Float = GhosttyRuntime.value(cfg, "font-size") { v.fontSize = Double(f) }
        if let s = GhosttyRuntime.string(cfg, "cursor-style") { v.cursorStyle = s }
        v.cursorBlink = GhosttyRuntime.value(cfg, "cursor-style-blink")
        if let b: Bool = GhosttyRuntime.value(cfg, "font-thicken") { v.fontThicken = b }
        if let b: Bool = GhosttyRuntime.value(cfg, "mouse-hide-while-typing") { v.mouseHide = b }
        if let s = GhosttyRuntime.string(cfg, "copy-on-select") { v.copyOnSelect = s != "none" }
        v.optionAsAlt = GhosttyRuntime.string(cfg, "macos-option-as-alt")
        return v
    }
}

// MARK: - Themes

struct GhosttyTheme: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let background: Color
    let foreground: Color
    let palette: [Color]

    /// Themes bundled with libghostty plus the user's own
    /// (~/.config/ghostty/themes), user ones winning on a name clash.
    static func loadAll() -> [GhosttyTheme] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes") { dirs.append(res) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        dirs.append(xdg.appendingPathComponent("ghostty/themes"))
        dirs.append(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/themes"))

        var byName: [String: GhosttyTheme] = [:]
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                if let t = parse(file) { byName[t.name] = t }
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parse(_ url: URL) -> GhosttyTheme? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var bg: Color?, fg: Color?
        var palette = [Color](repeating: .gray, count: 16)
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background": bg = Color(hex: parts[1])
            case "foreground": fg = Color(hex: parts[1])
            case "palette":
                let p = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, let i = Int(p[0]), i < 16, let c = Color(hex: p[1]) { palette[i] = c }
            default: break
            }
        }
        guard let bg, let fg else { return nil }
        return GhosttyTheme(name: url.lastPathComponent, background: bg, foreground: fg, palette: palette)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    init(_ c: ghostty_config_color_s) {
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// Installed fonts whose glyphs are all the same width.
enum MonospacedFonts {
    static func load() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { family in
            guard let first = fm.availableMembers(ofFontFamily: family)?.first,
                  let name = first.first as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Installed families that can render Simplified Chinese.
    static func loadCJK() -> [String] {
        let fm = NSFontManager.shared
        let probe = "中文简体，。".unicodeScalars
        return fm.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."),
                  let first = fm.availableMembers(ofFontFamily: family)?.first,
                  let name = first.first as? String,
                  let set = NSFont(name: name, size: 12)?.coveredCharacterSet else { return false }
            return probe.allSatisfy { set.contains($0) }
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - View

@MainActor
final class TerminalSettingsModel: ObservableObject {
    @Published var options = TerminalSettings.load() {
        didSet {
            guard options != oldValue else { return }
            TerminalSettings.save(options)
            schedule()
        }
    }
    @Published var user = GhosttyUserValues()
    @Published var themes: [GhosttyTheme] = []
    @Published var fonts: [String] = []
    @Published var cjkFonts: [String] = []
    private var pending: DispatchWorkItem?
    private var loaded = false

    func loadIfNeeded() {
        user = GhosttyUserValues.read()
        guard !loaded else { return }
        loaded = true
        Task.detached(priority: .userInitiated) {
            let themes = GhosttyTheme.loadAll()
            await MainActor.run { self.themes = themes }
        }
        // NSFontManager is happiest on the main thread; it's quick enough.
        fonts = MonospacedFonts.load()
        cjkFonts = MonospacedFonts.loadCJK()
    }

    /// Steppers fire continuously; settle before rebuilding the Ghostty config.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem {
            GhosttyRuntime.shared.reloadAppearance()
            NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

struct TerminalSettingsView: View {
    @StateObject private var model = TerminalSettingsModel()
    @State private var themeQuery = ""

    private var o: Binding<TerminalOptions> { $model.options }

    var body: some View {
        Form {
            Section {
                TerminalPreview(options: model.options, userFontSize: model.user.fontSize)
                    .listRowInsets(EdgeInsets())
            }

            Section("配色主题") {
                ThemePicker(themes: model.themes, selection: o.theme, query: $themeQuery)
            }

            Section("字体") {
                Picker("字体", selection: o.fontFamily) {
                    Text("跟随 Ghostty").tag(String?.none)
                    Divider()
                    if let f = model.options.fontFamily, !model.fonts.contains(f) {
                        Text(f).tag(Optional(f))
                    }
                    ForEach(model.fonts, id: \.self) { f in
                        Text(f).tag(Optional(f))
                    }
                }
                OptionalNumberRow(title: "字号", value: o.fontSize, follow: "\(fmt(model.user.fontSize)) pt",
                                  range: 6...36, step: 0.5, start: model.user.fontSize) { "\(fmt($0)) pt" }
                OptionalNumberRow(title: "行高", value: o.cellHeight, follow: "默认",
                                  range: -20...100, step: 5, start: 10) { "\($0 >= 0 ? "+" : "")\(Int($0))%" }
                TriStatePicker(title: "字体加粗", value: o.fontThicken, follow: model.user.fontThicken)
                Picker("中文字体", selection: o.cjkFont) {
                    Text("\(TerminalSettings.defaultCJKFont)（默认）").tag(String?.none)
                    Text("跟随 Ghostty（系统自动回退）").tag(Optional(""))
                    Divider()
                    if let f = model.options.cjkFont, !f.isEmpty, !model.cjkFonts.contains(f) {
                        Text(f).tag(Optional(f))
                    }
                    ForEach(model.cjkFonts.filter { $0 != TerminalSettings.defaultCJKFont }, id: \.self) { f in
                        Text(f).tag(Optional(f))
                    }
                }
            }

            Section("光标") {
                Picker("样式", selection: o.cursorStyle) {
                    Text("跟随 Ghostty（\(cursorName(model.user.cursorStyle))）").tag(String?.none)
                    Divider()
                    ForEach(["block", "bar", "underline", "block_hollow"], id: \.self) { s in
                        Text(cursorName(s)).tag(Optional(s))
                    }
                }
                TriStatePicker(title: "闪烁", value: o.cursorBlink, follow: model.user.cursorBlink)
            }

            Section("窗口") {
                OptionalNumberRow(title: "内边距", value: o.padding, follow: "默认",
                                  range: 0...40, step: 2, start: 8) { "\(Int($0)) pt" }
            }

            Section("输入") {
                Picker("Option 键作为 Alt", selection: o.optionAsAlt) {
                    Text("跟随 Ghostty（\(altName(model.user.optionAsAlt))）").tag(String?.none)
                    Divider()
                    ForEach(["true", "left", "right", "false"], id: \.self) { s in
                        Text(altName(s)).tag(Optional(s))
                    }
                }
                TriStatePicker(title: "选中即复制", value: o.copyOnSelect, follow: model.user.copyOnSelect)
                TriStatePicker(title: "输入时隐藏鼠标", value: o.mouseHide, follow: model.user.mouseHide)
            }

            Section {
                HStack {
                    Button("打开 Ghostty 配置文件") { GhosttyRuntime.openUserConfig() }
                    Spacer()
                    Button("全部恢复为跟随 Ghostty") { model.options = TerminalOptions() }
                        .disabled(model.options.isEmpty)
                }
            } footer: {
                Text("这里的设置叠加在你的 Ghostty 配置之上，修改后立即应用到所有终端；选择「跟随 Ghostty」则沿用 Ghostty 配置文件里的值。如果配置文件里直接写了 background 等颜色，它们会盖过主题。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 680)
        .onAppear { model.loadIfNeeded() }
    }

    private func fmt(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)
    }

    private func cursorName(_ s: String) -> String {
        switch s {
        case "bar": return "竖线"
        case "underline": return "下划线"
        case "block_hollow": return "空心方块"
        default: return "方块"
        }
    }

    private func altName(_ s: String?) -> String {
        switch s {
        case "true": return "两侧"
        case "left": return "仅左侧"
        case "right": return "仅右侧"
        default: return "关闭"
        }
    }
}

/// "跟随 Ghostty（开）" / 开 / 关
private struct TriStatePicker: View {
    let title: String
    @Binding var value: Bool?
    let follow: Bool?

    var body: some View {
        Picker(title, selection: $value) {
            Text("跟随 Ghostty（\(follow.map { $0 ? "开" : "关" } ?? "默认")）").tag(Bool?.none)
            Divider()
            Text("开").tag(Bool?.some(true))
            Text("关").tag(Bool?.some(false))
        }
    }
}

private struct OptionalNumberRow: View {
    let title: String
    @Binding var value: Double?
    let follow: String
    let range: ClosedRange<Double>
    let step: Double
    let start: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            if let v = value {
                HStack(spacing: 6) {
                    Text(format(v)).monospacedDigit()
                    Stepper("", value: Binding(get: { v }, set: { value = $0 }), in: range, step: step)
                        .labelsHidden()
                    Button { value = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("恢复为跟随 Ghostty")
                }
            } else {
                HStack(spacing: 8) {
                    Text("跟随 Ghostty（\(follow)）").foregroundStyle(.secondary)
                    Button("自定义") { value = min(max(start, range.lowerBound), range.upperBound) }
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ThemePicker: View {
    let themes: [GhosttyTheme]
    @Binding var selection: String?
    @Binding var query: String

    private var filtered: [GhosttyTheme] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? themes : themes.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 \(themes.count) 个主题", text: $query)
                    .textFieldStyle(.plain)
                if let s = selection {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if query.isEmpty {
                            row(name: "跟随 Ghostty", theme: nil, selected: selection == nil) { selection = nil }
                                .id("__follow")
                        }
                        ForEach(filtered) { t in
                            row(name: t.name, theme: t, selected: selection == t.name) { selection = t.name }
                                .id(t.name)
                        }
                    }
                }
                .frame(height: 210)
                .onAppear { if let s = selection { proxy.scrollTo(s, anchor: .center) } }
                .onChange(of: themes.count) { _, _ in
                    if let s = selection { proxy.scrollTo(s, anchor: .center) }
                }
            }
        }
    }

    private func row(name: String, theme: GhosttyTheme?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ThemeSwatch(theme: theme)
                Text(name).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

private struct ThemeSwatch: View {
    let theme: GhosttyTheme?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme?.background ?? Color.secondary.opacity(0.2))
            if let theme {
                HStack(spacing: 2) {
                    Text("A").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.foreground)
                    ForEach(1..<7, id: \.self) { i in
                        Circle().fill(theme.palette[i]).frame(width: 5, height: 5)
                    }
                }
            } else {
                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 20)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12)))
    }
}

/// A fake agent session drawn with the terminal's live colors, so theme and
/// font changes are visible without looking at the main window.
private struct TerminalPreview: View {
    let options: TerminalOptions
    let userFontSize: Double
    @State private var colors = GhosttyRuntime.shared.currentColors()

    private var font: Font {
        let size = min(options.fontSize ?? userFontSize, 18)
        if let family = options.fontFamily,
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(f)
        }
        if let f = NSFont(name: "JetBrainsMono-Regular", size: size) { return Font(f) }
        return .system(size: size, design: .monospaced)
    }

    var body: some View {
        let p = colors.palette
        VStack(alignment: .leading, spacing: 2 + CGFloat(options.cellHeight ?? 0) / 20) {
            (Text("~/agentdeck ").foregroundColor(p[4]) + Text("main ").foregroundColor(p[5])
                + Text("❯ ").foregroundColor(p[2]) + Text("claude").foregroundColor(colors.foreground))
            (Text("● ").foregroundColor(p[6]) + Text("Reading Sources/UI/TerminalSettings.swift")
                .foregroundColor(colors.foreground))
            (Text("  + 128 added  ").foregroundColor(p[2]) + Text("- 12 removed").foregroundColor(p[1]))
            (Text("  ⚠ ").foregroundColor(p[3]) + Text("waiting for permission").foregroundColor(p[8]))
            HStack(spacing: 0) {
                Text("❯ ").foregroundColor(p[2])
                cursor
            }
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10 + CGFloat(options.padding ?? 0) / 2)
        .background(colors.background)
        .onReceive(NotificationCenter.default.publisher(for: AppearanceSettings.changed)) { _ in
            colors = GhosttyRuntime.shared.currentColors()
        }
    }

    @ViewBuilder private var cursor: some View {
        let h = min(options.fontSize ?? userFontSize, 18) * 1.2
        switch options.cursorStyle {
        case "bar": Rectangle().fill(colors.foreground).frame(width: 2, height: h)
        case "underline": Rectangle().fill(colors.foreground).frame(width: h * 0.55, height: 2)
            .frame(height: h, alignment: .bottom)
        case "block_hollow": Rectangle().strokeBorder(colors.foreground, lineWidth: 1).frame(width: h * 0.55, height: h)
        default: Rectangle().fill(colors.foreground).frame(width: h * 0.55, height: h)
        }
    }
}
