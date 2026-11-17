<p align="center">
  <img src="Resources/AppIcon-1024.png" alt="AgentDeck 图标" width="128">
</p>

<h1 align="center">AgentDeck</h1>

<p align="center">
  <strong>一个窗口，看住所有 Agent。</strong><br>
  给 AI 编程 Agent 用的原生 macOS 工作台，本地和服务器上的 Agent 并排跑。<br>
  每一格都是真正的 <a href="https://ghostty.org">Ghostty</a> 终端。
</p>

<p align="center">
  <a href="https://github.com/CassianFlorin/AgentDeck/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/CassianFlorin/AgentDeck?label=release&color=3eecc8"></a>
  <img alt="macOS 14+，Apple 芯片" src="https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-black?logo=apple">
  <a href="#安装"><img alt="Homebrew" src="https://img.shields.io/badge/brew-cassianflorin%2Ftap%2Fagentdeck-orange?logo=homebrew"></a>
  <a href="LICENSE"><img alt="MIT 许可" src="https://img.shields.io/github/license/CassianFlorin/AgentDeck"></a>
</p>

<p align="center">
  <a href="https://agentdeck.cassianflorin.com">官网</a> ·
  <a href="https://github.com/CassianFlorin/AgentDeck/releases/latest">下载</a> ·
  <a href="docs/FEATURES.md">全部功能（英文）</a> ·
  <a href="README.md">English</a>
</p>

---

用 AI 写代码，往往是好几个 Agent 一起跑：一个仓库里开着 Claude Code，另一个开着 Codex，服务器上还有一个。终端标签页越开越多，你得来回翻：哪个还在跑，哪个卡在权限确认上等你，窗口关掉以后那段对话又去哪了。

AgentDeck 把它们放进一个窗口，用一条侧边栏管理所有会话，并告诉你哪个在等你。

## 亮点

- **谁在等你，一眼看清。** 每个 Agent 都有状态：运行中、等你、本轮完成、已退出。`⌘⇧J` 直接跳到下一个在等你的。
- **所有 Agent 列在一屏。** Agent 总览（`⇧⌘A`）列出所有会话里的 Agent，等你的排最前。不用切过去就能看最后几行输出、回答提示、停下这一轮，也能在同一个地方派新任务。
- **本地和远程在同一条侧边栏。** `~/.ssh/config` 里的服务器直接出现在本地会话旁边。服务器上有 tmux 或 zellij 就用上，断线重连后 Agent 还在原地跑。服务器上不用装任何东西。
- **重新打开，接着之前的工作。** 重启 App 后，会话、分屏、分组和 SSH 连接按原样回来，Agent 回到同一段对话。`⇧⌘O` 按文件夹列出以前的对话。
- **自动检测装了哪些 Agent。** AgentDeck 在登录 shell 的 PATH 里找 Agent 命令行工具，菜单里只列找到的；没装的可以在 App 里直接安装。
- **真正的终端。** 沿用你的 Ghostty 配置、主题和快捷键。分屏、查找、中日韩输入法、截图贴成路径，还有性能面板（含 Docker），看的是当前会话所在的 Mac 或服务器。

## 支持的 Agent

| Agent | 恢复对话 | 派发任务 | 状态来源 |
| --- | :---: | :---: | --- |
| Claude Code | 精确 | ✓ | hooks，内置 |
| Codex | 精确 | ✓ | hooks，需手动开启 |
| Grok | 精确 | ✓ | hooks，需手动开启 |
| Gemini | 最近一段 | ✓ | 通用信号 |
| opencode | 最近一段 | ✓ | 通用信号 |
| Qwen Code | 最近一段 | ✓ | 通用信号 |
| Cursor CLI | 最近一段 | ✓ | 通用信号 |
| Copilot CLI | 最近一段 | ✓ | 通用信号 |
| Droid | 最近一段 | ✓ | 通用信号 |
| Aider | 最近一段 | | 通用信号 |
| Amp | | | 通用信号 |
| Crush | | | 通用信号 |
| 其他命令行工具 | 自己填参数 | 自己填参数 | 通用信号 |

- **恢复对话**：「精确」是按对话 id 回到同一段；「最近一段」是接着这个文件夹里最近的那段对话。
- **状态来源**：「hooks」是 Agent 自己报告状态。Claude Code 的 hooks 在启动时带上，不改你的设置文件；Codex 和 Grok 要在「管理 Agent」里打开。「通用信号」是从回车、响铃、通知、进度和 Agent 退出推断出来的。

## 安装

```bash
brew install --cask cassianflorin/tap/agentdeck
```

也可以从 [Releases](https://github.com/CassianFlorin/AgentDeck/releases/latest) 下载 DMG。已用 Apple Developer ID 签名并通过公证，装好后会自己更新。需要 macOS 14 或更新版本，Apple 芯片。

## 快捷键

| 快捷键 | |
| --- | --- |
| `⌘⇧J` | 跳到下一个等你的会话 |
| `⇧⌘A` | 打开 Agent 总览 |
| `⌥⌘[` `⌥⌘]` | 上一个 / 下一个 Agent，跨会话 |
| `⌘D` `⌘⇧D` | 向右 / 向下分屏 |
| `⇧⌘O` | 恢复这个文件夹里以前的对话 |
| `⌘⇧R` | 重新连接 SSH |

完整列表见 [docs/FEATURES.md](docs/FEATURES.md)（英文）。

## 从源码构建

需要 Xcode 16+、[XcodeGen](https://github.com/yonaskolb/XcodeGen) 和 Zig。最短的步骤：

```bash
git clone --recursive https://github.com/CassianFlorin/AgentDeck.git
cd AgentDeck
scripts/build-ghosttykit.sh && scripts/fetch-sparkle.sh
xcodegen && open AgentDeck.xcodeproj
```

常见问题和发版流程见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 关于

AgentDeck 是照着我自己的工作流做的，开源出来，也许正好适合你。欢迎提 issue 和想法。

终端引擎是 Mitchell Hashimoto 和贡献者们的 [Ghostty](https://github.com/ghostty-org/ghostty)（MIT）。应用内更新用的是 [Sparkle](https://sparkle-project.org)。

MIT 许可，见 [LICENSE](LICENSE)。
