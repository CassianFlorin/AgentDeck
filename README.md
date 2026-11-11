# AgentDeck

A native macOS workbench for running several AI coding agents (Claude Code, Codex, or a plain shell) side by side, built on [libghostty](https://ghostty.org).

You get one window and a sidebar of sessions. Each session is a real Ghostty terminal running in its own folder. When an agent rings the bell or sends a desktop notification (it finished, or it needs permission) while you're looking at a different session, that session gets an orange dot and the Dock icon gets a badge.

> Status: early skeleton (v0.1). Expect rough edges.

## Features

- **Sessions sidebar.** Every session keeps running in the background. Switch with `⌘⇧[` / `⌘⇧]`.
- **Agent presets.** Claude Code, Codex, and Shell. The agent command is typed into your login shell, so you drop back to a working shell when the agent exits.
- **"Needs you" tracking.** Bell and OSC 9/777 notifications become a sidebar dot and a Dock badge. `⌘⇧J` jumps to the next waiting session.
- **Your Ghostty config just works.** AgentDeck loads `~/.config/ghostty/config`, so your fonts, themes and keybinds carry over.
- **IME support.** Chinese, Japanese and Korean input methods work, with the candidate window anchored at the cursor.
- **Splits.** `⌘D` / `⌘⇧D` split right/down; `⌘[` `⌘]` or `⌘⌥←↑↓→` move between panes; `⌘⌃←↑↓→` resize; `⌘⇧↩` zoom; `⌃⌘=` equalize. New panes inherit the current folder. Layouts are restored on relaunch.
- **Find & scrollback.** `⌘F` to find, `↩` / `⇧↩` (or `⌘G` / `⇧⌘G`) to step through matches, with a match counter. `⌘E` searches the current selection. An overlay scroll indicator can be dragged. `⌘↑` / `⌘↓` jump between prompts.
- **Paste images and files.** `⌘V` with a screenshot on the clipboard saves it as a PNG and pastes its path, which is how you hand an agent an image. Copied or dragged files paste as shell-escaped paths.
- **Rename & group sessions.** Right-click a session to rename it or move it into a group. Groups are collapsible sidebar sections. `⌘1`–`⌘9` jump to a session.
- **Restore on relaunch.** The same agents reopen in the same folders, as fresh processes.

## Roadmap

1. **Shell.** A solid everyday terminal: tabs/splits, search, scrollback, image paste, session rename and grouping.
2. **Remote servers (ECS / VPS / any SSH host).** Saved host configs with an editor for adding them, connect in one click, and restore sessions after reconnecting (tmux/zellij attach).
3. **Agent shells.** First-class management for Claude Code, Codex, Grok, Gemini and others: presets, per-agent status, resuming previous conversations.

## Build

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Zig (the version in `vendor/ghostty/build.zig.zon` → `minimum_zig_version`).

```bash
git clone --recursive https://github.com/CassianFlorin/AgentDeck.git
cd AgentDeck
scripts/build-ghosttykit.sh      # builds vendor/GhosttyKit.xcframework (~5 min first time)
xcodegen
open AgentDeck.xcodeproj
```

On Xcode 26 and later, the Metal compiler is a separate component. Install it once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Troubleshooting:

- **Zig's fetch fails.** You might see `400 Bad Request` behind an HTTP proxy, or `hash mismatch` / `DirNotEmpty` on some macOS versions. Prefetch the dependencies with curl (which respects `https_proxy`), then build without Zig's own network access:

  ```bash
  scripts/prefetch-zig-deps.sh
  ZIG_SYSTEM_DIR=vendor/zig-deps/pkg scripts/build-ghosttykit.sh
  ```

- **`hash mismatch` after an interrupted build.** Run `CLEAN=1 scripts/build-ghosttykit.sh`.

## Claude Code tip

To make Claude Code tell AgentDeck when it's waiting for you, run:

```bash
claude config set --global preferredNotifChannel terminal_bell
```

## Credits

The terminal engine is [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors (MIT). The input and IME handling is adapted from Ghostty's macOS app.

## License

MIT. See [LICENSE](LICENSE).
