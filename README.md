<p align="center">
  <img src="Resources/AppIcon-1024.png" alt="AgentDeck icon" width="128">
</p>

<h1 align="center">AgentDeck</h1>

<p align="center">
  <strong>One window for every coding agent.</strong><br>
  A native macOS workbench for running AI coding agents side by side, locally or on your servers.<br>
  Every pane is a real <a href="https://ghostty.org">Ghostty</a> terminal.
</p>

<p align="center">
  <a href="https://github.com/CassianFlorin/AgentDeck/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/CassianFlorin/AgentDeck?label=release&color=3eecc8"></a>
  <img alt="macOS 14+ on Apple silicon" src="https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-black?logo=apple">
  <a href="#install"><img alt="Homebrew" src="https://img.shields.io/badge/brew-cassianflorin%2Ftap%2Fagentdeck-orange?logo=homebrew"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/CassianFlorin/AgentDeck"></a>
</p>

<p align="center">
  <a href="https://agentdeck.cassianflorin.com">Website</a> ·
  <a href="https://github.com/CassianFlorin/AgentDeck/releases/latest">Download</a> ·
  <a href="docs/FEATURES.md">All features</a> ·
  <a href="README.zh-CN.md">中文</a>
</p>

---

Coding with AI agents usually means running several at once: Claude Code in one repo, Codex in another, a third on a server. That quickly turns into a pile of terminal tabs, and you keep checking which agent is still working, which one is stuck on a permission prompt, and where a conversation went after the window closed.

AgentDeck puts them in one window with a sidebar of sessions, and tells you which ones need you.

## Highlights

- **See who needs you.** Every agent shows whether it is working, waiting for you, done with its turn, or exited. `⌘⇧J` jumps to the next one that is waiting.
- **Every agent on one screen.** The Agent overview (`⇧⌘A`) lists all agents across sessions, waiting ones first. Read their last lines, answer a prompt, or stop a turn without leaving the list, and hand out new tasks from the same place.
- **Local and remote in one sidebar.** Servers from `~/.ssh/config` show up next to your local sessions. AgentDeck uses tmux or zellij on the server if it is there, so a dropped connection reattaches with the agent still running. Nothing is installed on the server.
- **Pick up where you were.** Sessions, splits, groups and SSH connections come back after a relaunch, and agents return to the same conversation. `⇧⌘O` lists past conversations for a folder.
- **Your agents, detected.** AgentDeck finds the agent CLIs on your login shell's PATH and lists only those. Missing ones install from inside the app.
- **A real terminal.** Your Ghostty config, themes and keybinds carry over. Splits, find, CJK input methods, pasting screenshots as paths, and a performance panel with Docker for the Mac or the server you are on.

## Supported agents

| Agent | Restores its conversation | Hand out tasks | Status |
| --- | :---: | :---: | --- |
| Claude Code | exact | ✓ | hooks, built in |
| Codex | exact | ✓ | hooks, opt-in |
| Grok | exact | ✓ | hooks, opt-in |
| Gemini | latest | ✓ | generic |
| opencode | latest | ✓ | generic |
| Qwen Code | latest | ✓ | generic |
| Cursor CLI | latest | ✓ | generic |
| Copilot CLI | latest | ✓ | generic |
| Droid | latest | ✓ | generic |
| Aider | latest | | generic |
| Amp | | | generic |
| Crush | | | generic |
| Any other CLI | your arguments | your arguments | generic |

- **Restores its conversation:** *exact* returns to the same conversation by id; *latest* continues the most recent one in the folder.
- **Status:** *hooks* means the agent reports its state itself. AgentDeck passes Claude Code's hooks at launch without touching your settings; for Codex and Grok you turn them on in Manage Agents. *generic* status comes from Return, the bell, notifications, progress and the agent exiting.

## Install

```bash
brew install --cask cassianflorin/tap/agentdeck
```

Or download the DMG from [Releases](https://github.com/CassianFlorin/AgentDeck/releases/latest). It is signed with a Developer ID and notarized by Apple, and updates itself from then on. Requires macOS 14 or later on Apple silicon.

## Keys

| Keys | |
| --- | --- |
| `⌘⇧J` | Jump to the next session that needs you |
| `⇧⌘A` | Agent overview |
| `⌥⌘[` `⌥⌘]` | Previous / next agent, across sessions |
| `⌘D` `⌘⇧D` | Split right / down |
| `⇧⌘O` | Resume an earlier conversation for this folder |
| `⌘⇧R` | Reconnect SSH |

The full list is in [docs/FEATURES.md](docs/FEATURES.md).

## Build from source

You need Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Zig. The short version:

```bash
git clone --recursive https://github.com/CassianFlorin/AgentDeck.git
cd AgentDeck
scripts/build-ghosttykit.sh && scripts/fetch-sparkle.sh
xcodegen && open AgentDeck.xcodeproj
```

Troubleshooting and the release process are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## About

AgentDeck is a personal tool, built for my own workflow and open-sourced in case it fits yours. Issues and ideas are welcome.

The terminal engine is [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors (MIT). Updates are delivered with [Sparkle](https://sparkle-project.org).

MIT licensed. See [LICENSE](LICENSE).
