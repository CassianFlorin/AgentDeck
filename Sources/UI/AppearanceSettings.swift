import SwiftUI

/// 设置 → 外观: dark, translucent ("glass") window with adjustable opacity.
///
/// The terminal side is libghostty's own `background-opacity` / `background-blur`,
/// written as an overlay on top of the user's Ghostty config, so the terminal,
/// the title bar and the sidebar glass all see the same blurred desktop.
enum AppearanceSettings {
    static let opacityKey = "appearance.backgroundOpacity"
    static let blurKey = "appearance.backgroundBlur"
    static let defaultOpacity = 0.8
    static let minOpacity = 0.3

    static var opacity: Double {
        let d = UserDefaults.standard
        let v = d.object(forKey: opacityKey) == nil ? defaultOpacity : d.double(forKey: opacityKey)
        return min(max(v, minOpacity), 1)
    }

    static var blur: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: blurKey) == nil ? true : d.bool(forKey: blurKey)
    }

    static var isTranslucent: Bool { opacity < 0.999 }

    /// When translucent the window itself paints the terminal's background
    /// color at this opacity, behind everything (terminal, title bar, sidebar
    /// glass), and the terminal draws no background of its own. One tint
    /// layer means the sidebar glass has something dark to refract and every
    /// part of the window ends up the same shade.
    static var ghosttyOverlay: String {
        """
        # Written by AgentDeck (设置 → 外观). Edits here are overwritten.
        background-opacity = \(isTranslucent ? "0" : "1")
        background-blur = \(blur && isTranslucent ? 20 : 0)

        """
    }

    static let changed = Notification.Name("AgentDeckAppearanceChanged")
}

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceSettings.opacityKey) private var opacity = AppearanceSettings.defaultOpacity
    @AppStorage(AppearanceSettings.blurKey) private var blur = true
    @State private var pending: DispatchWorkItem?

    var body: some View {
        Form {
            Section {
                LabeledContent("背景不透明度") {
                    HStack {
                        Slider(value: $opacity, in: AppearanceSettings.minOpacity...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                        Text("\(Int((opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("模糊背景（毛玻璃）", isOn: $blur)
                    .disabled(opacity >= 0.999)
            } footer: {
                Text("调低后可以透过窗口看到桌面。终端的文字始终不透明。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onChange(of: opacity) { _, _ in schedule() }
        .onChange(of: blur) { _, _ in schedule() }
    }

    /// The slider fires continuously; rebuilding the Ghostty config on every
    /// tick is wasteful, so settle first.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem {
            GhosttyRuntime.shared.reloadAppearance()
            NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

/// Makes the hosting window translucent and blurred to match the settings.
struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }
    func updateNSView(_ view: ConfiguratorView, context: Context) { view.apply() }

    final class ConfiguratorView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: AppearanceSettings.changed, object: nil, queue: .main
                ) { [weak self] _ in self?.apply() }
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func apply() {
            guard let window else { return }
            if AppearanceSettings.isTranslucent {
                window.isOpaque = false
                window.backgroundColor = GhosttyRuntime.shared.backgroundColor
                    .withAlphaComponent(AppearanceSettings.opacity)
            } else {
                window.isOpaque = true
                window.backgroundColor = GhosttyRuntime.shared.backgroundColor
            }
            GhosttyRuntime.shared.applyBackgroundBlur(to: window)
        }
    }
}
