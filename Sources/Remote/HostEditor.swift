import SwiftUI

/// Add / edit a server.
struct HostEditor: View {
    @State var host: RemoteHost
    let isNew: Bool
    let onSave: (RemoteHost, _ password: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var portText = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    /// A password written to the Keychain only so "测试连接" could use it.
    @State private var storedForTest = false

    private let providers = ["ECS", "VPS", "Lightsail", "EC2", "家里", "公司"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $host.name, prompt: Text("例如：生产 · 杭州"))
                    TextField("主机", text: $host.host, prompt: Text("IP、域名或 ~/.ssh/config 里的别名"))
                    HStack {
                        TextField("用户", text: optional($host.user), prompt: Text("默认按 ssh 配置"))
                        TextField("端口", text: $portText, prompt: Text("22"))
                            .frame(width: 120)
                    }
                    HStack {
                        TextField("类型", text: optional($host.provider), prompt: Text("ECS / VPS …"))
                        Menu("常用") {
                            ForEach(providers, id: \.self) { p in Button(p) { host.provider = p } }
                        }
                        .fixedSize()
                    }
                    TextField("分组", text: optional($host.group), prompt: Text("可选，连接后会话放进这个分组"))
                }

                Section("认证") {
                    Picker("方式", selection: $host.auth) {
                        ForEach(RemoteHost.Auth.allCases) { Text($0.label).tag($0) }
                    }
                    if host.auth == .key {
                        HStack {
                            TextField("私钥", text: optional($host.identityFile), prompt: Text("~/.ssh/id_ed25519"))
                            Button("选择…", action: pickKey)
                        }
                    }
                    if host.auth == .password {
                        SecureField("密码", text: $password,
                                    prompt: Text(HostKeychain.hasPassword(for: host.id) ? "已保存在钥匙串（留空不修改）" : "保存到钥匙串"))
                    }
                    TextField("跳板机", text: optional($host.jumpHost), prompt: Text("可选，ProxyJump，如 bastion 或 user@jump:22"))
                }

                Section("会话") {
                    Picker("断线保持", selection: $host.persistence) {
                        ForEach(RemoteHost.Persistence.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("登录后目录", text: optional($host.remoteDirectory), prompt: Text("可选，例如 /srv/app"))
                    TextField("TERM", text: $host.term)
                    TextField("额外 ssh 参数", text: optional($host.extraArguments),
                              prompt: Text("可选，例如 -o StrictHostKeyChecking=accept-new"))
                }

                Section("命令预览") {
                    Text(SSH.commandLine(for: normalized, sessionName: host.persistence.usesSessionName ? "agentdeck" : nil))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                if let r = testResult {
                    Section("测试结果") {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(r.ok ? .green : .orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(action: test) {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                }
                .disabled(host.host.isEmpty || testing)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear { portText = host.port.map(String.init) ?? "" }
    }

    /// Host with the port text applied and empty strings turned into nil.
    private var normalized: RemoteHost {
        var h = host
        h.port = Int(portText.trimmingCharacters(in: .whitespaces))
        h.host = h.host.trimmingCharacters(in: .whitespaces)
        if h.name.trimmingCharacters(in: .whitespaces).isEmpty { h.name = h.host }
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty ? nil : t
        }
        h.user = clean(h.user)
        h.provider = clean(h.provider)
        h.group = clean(h.group)
        h.identityFile = clean(h.identityFile)
        h.jumpHost = clean(h.jumpHost)
        h.remoteDirectory = clean(h.remoteDirectory)
        h.extraArguments = clean(h.extraArguments)
        if h.term.trimmingCharacters(in: .whitespaces).isEmpty { h.term = "xterm-256color" }
        return h
    }

    private func cancel() {
        // Don't leave a Keychain item behind for a host that was never added.
        if isNew && storedForTest { HostKeychain.deletePassword(for: host.id) }
        dismiss()
    }

    private func save() {
        onSave(normalized, password.isEmpty ? nil : password)
        dismiss()
    }

    private func test() {
        let h = normalized
        // A test with a new password needs it in the Keychain first.
        if h.auth == .password, !password.isEmpty {
            HostKeychain.setPassword(password, for: h.id, label: h.name)
            storedForTest = true
        }
        testing = true
        testResult = nil
        Task {
            let r = await SSH.inspect(h)
            await MainActor.run {
                testing = false
                switch r {
                case .success(let info):
                    var parts = ["连接成功", info.system]
                    switch (h.persistence, info.multiplexer(for: h.persistence)) {
                    case (.none, _):
                        break
                    case (_, let mux?):
                        parts.append("会用 \(mux) 保持会话，服务器上现有 \(info.sessions.count) 个")
                    case (.auto, nil):
                        parts.append("服务器上没有 tmux / zellij，将使用普通 shell（断线后重新登录；装了 tmux 就能断线续上）")
                    case (let p, nil):
                        parts.append("服务器上没有 \(p.rawValue)，断线后无法恢复；可改为“自动”")
                    }
                    testResult = (true, parts.filter { !$0.isEmpty }.joined(separator: " · "))
                case .failure(let e):
                    testResult = (false, e.message.isEmpty ? "连接失败" : e.message)
                }
            }
        }
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            host.identityFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0 })
    }
}

/// Pick an existing tmux/zellij session on a server, or start a new one.
struct RemoteSessionPicker: View {
    let host: RemoteHost
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var sessions: [String] = []
    @State private var error: String?
    @State private var newName = ""
    @State private var mux: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(host.name) 上的\(mux.map { " \($0) " } ?? "")会话")
                .font(.headline)
            Group {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("正在连接…").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if mux == nil {
                    Text("服务器上没有 tmux / zellij，无法附加已有会话；可以直接新建一个普通 shell 会话。")
                        .foregroundStyle(.secondary)
                } else if sessions.isEmpty {
                    Text("服务器上还没有会话").foregroundStyle(.secondary)
                } else {
                    List(sessions, id: \.self) { name in
                        HStack {
                            Image(systemName: "rectangle.on.rectangle")
                            Text(name)
                            Spacer()
                            Button("附加") { pick(name) }
                        }
                    }
                    .frame(minHeight: 140)
                }
            }
            HStack {
                TextField("新会话名", text: $newName, prompt: Text("留空自动命名"))
                Button("新建") { pick(newName.isEmpty ? nil : SSH.sessionName(newName)) }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await load() }
    }

    private func load() async {
        let r = await SSH.inspect(host)
        loading = false
        switch r {
        case .success(let info):
            sessions = info.sessions
            mux = info.multiplexer(for: host.persistence)
        case .failure(let e): error = e.message.isEmpty ? "连接失败" : e.message
        }
    }

    private func pick(_ name: String?) {
        onPick(name)
        dismiss()
    }
}
