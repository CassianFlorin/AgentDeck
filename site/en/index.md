<!-- https://waitlight.cassianflorin.com/en/ as Markdown, generated from the page by scripts/build-site.py -->

Waitlight is a native macOS app for running multiple AI coding agents (Claude Code, Codex, Gemini and more) side by side, locally or over SSH, with one sidebar that shows which agent needs you. Built on Ghostty. Free and open source.

A native macOS workbench for coding agents

# One window for every agent.

**See who is working and who is waiting on you.** Coding agents, local folders, and SSH sessions, all in one window.

macOS 14 or later · Apple silicon · Free, MIT

Works with

- Claude Code
- Codex
- Gemini
- Grok
- opencode
- Qwen Code
- Cursor CLI
- Copilot CLI
- Droid
- Amp
- Crush
- Aider
- + any CLI

Waitlight detects which ones you have and lists only those. Install the rest from inside the app.

## See who needs you without switching over.

Every agent carries a status light. Four colors, four meanings.

- **Working**: This turn is still going. You can leave it to it.
- **Needs you**: It stopped for a confirmation or an answer. `⌘⇧J` jumps to the next.
- **Turn done**: The turn is finished and the session is still there. Read the result, or carry on.
- **Exited**: The agent exited and you are back at the shell. Supported agents can resume the earlier conversation.
- Claude Code reports through its own hooks. Waitlight passes flags at launch and never edits your settings files.
- Grok and Codex can report the same way once you turn it on in Manage Agents. They only read hooks from their own config folder, so each gets one new file of Waitlight's own: ~/.grok/hooks/waitlight.json and ~/.codex/waitlight.config.toml. Your existing config is left as it is, turning the switch off deletes the file, and the hook does nothing outside Waitlight. Both agents ask you to trust a new hook first.
- Agents without hooks are read from generic signals: Return, the bell, notifications, and progress.
- Right after launch, before the first prompt, the label is 就绪 (ready). A plain shell has none of these states.
- Bells and notifications also badge the Dock. A dropped SSH session is marked 已断开 (disconnected) with a reconnect button; `⌘⇧R` reconnects too.
- The motion means something: while working, a light sweeps across the label; while waiting, a ring expands from the dot. With Reduce Motion on, the animation stops.

## Every agent, on one screen.

`⇧⌘A` swaps the terminal for a list, one row per agent. Every session keeps running behind it.

- Waiting comes first: Agents that need you sort to the top, and the row says what each is waiting for and for how long.
- Answer without leaving: Select a row to see the last lines of its terminal. Type and press Return, or press one of its option keys, and the answer is sent.
- Hand out the next task: Pick the agent and the folder in the bar, write the task, press Return. A new agent starts in the background and you stay on the list.
- **Filter**: the field at the top matches name, agent, or folder. You can also group by folder.
- **Pin**: right-click to pin an agent. It stays at the top whatever it is doing, and stays pinned after a relaunch.
- **Stop**: a working agent can be stopped for this turn.
- **Quick keys**: when it asks you to choose, `1 2 3 ↩ esc` next to the reply field answer its prompt.
- **In and out**: `↩` or a double-click opens its session with the cursor in its pane. `esc`, or any session in the sidebar, returns to the terminal.

## Local and remote, in the same sidebar.

Hosts from ~/.ssh/config show up under Servers, with nothing to install on them. After a reconnect, a session running in tmux or zellij attaches right where it was.

- Servers lists hosts you add and every alias in ~/.ssh/config, including files pulled in with Include. You can set the address, user, port, key or ssh-agent, and ProxyJump. Passwords go in the Keychain.
- Auto is the default: if the machine already has tmux or zellij, Waitlight uses it. If not, you get a normal login shell, with no prompt to install anything.
- On reconnect, a session that was in tmux or zellij attaches again, so the agent is still there. Without a multiplexer, it logs in again in the directory you set, and the earlier processes are gone.
- The performance panel follows the selected session. For SSH it samples that server over one connection: a small POSIX shell loop reading /proc, still with nothing to install. Remote sampling currently supports Linux only.

## Open it again and pick up where you were.

Relaunch the app, or start an agent that had exited, and Claude Code, Grok, and Codex return to the same conversation. Splits, groups, and SSH connections come back the way you left them.

- Returning to the same conversation depends on a conversation id. Claude Code and Grok start with an id Waitlight assigns. Codex cannot be given one up front: once it has received its first prompt and written its session file, Waitlight matches the id from ~/.codex/sessions.
- Without an id (Gemini, or Codex before its first prompt): relaunching the app continues the most recent conversation in that folder, while restarting an exited agent inside the app starts a new conversation.
- `⇧⌘O` lists past conversations for a folder, so you can resume one. It covers Claude Code, Codex, and Grok.
- Custom agents: Waitlight generates an id and returns to the same conversation only when both the new-conversation and the resume arguments contain {id}. With only the continue-latest arguments filled in, relaunching the app continues the most recent conversation. With neither, every start is a new conversation.
- Sessions opened from a Docker container are not restored on the next launch. With nothing to restore, Waitlight opens a shell in your home directory.

### Every pane is a real Ghostty terminal

~/.config/ghostty/config

Fonts, themes, and keybinds come straight from your Ghostty config. Changes made in Waitlight's settings are layered on top and never written back to the file.

## Keep your hands on the keyboard.

- `⌘⇧J` — Jump to the next session that needs you
- `⇧⌘A` — Open the agent overview
- `⌥⌘[ ⌥⌘]` — Previous / next agent, across sessions
- `⌘D ⌘⇧D` — Split right / split down
- `⇧⌘O` — Resume an earlier conversation for this folder
- `⌘⇧R` — Reconnect SSH
- `⌘⇧[ ⌘⇧]` — Previous / next session
- `⌘1 ⌘9` — Jump to a session by number
- `⌘⇧↩` — Zoom / restore the current pane
- `⌘F` — Find in the scrollback
- `⌘V` — Paste a screenshot or file as a path
- `⌥⌘P` — Open the performance panel
- `⌘⇧W` — Close the current session
- `⌘,` — Settings
- The mainstream agent CLIs are built in: Claude Code, Codex, Gemini, Grok, opencode, Qwen Code, Cursor CLI, Copilot CLI, Droid, Amp, Crush, and Aider, plus a shell. The new-session menu lists only the ones you have installed. For the rest, Install in Manage Agents runs the install command in a new terminal, and the agent shows up in the menu once it is done. Any other CLI can be added.
- An agent's command is typed into your login shell, so when the agent exits you are still in that shell.
- Status belongs to the pane, not the session. Type claude or codex into a split yourself and Waitlight notices: it gets its own status and its own row in the overview.
- If the clipboard holds a screenshot, ⌘V saves a PNG and pastes the path, which is how you hand an image to an agent. Copied or dragged files paste as shell-escaped paths.
- Chinese, Japanese, and Korean input methods work, with the candidate window anchored at the cursor.
- Sessions can be renamed or moved into a group. A group is a collapsible section in the sidebar.
- The performance panel also lists Docker containers. You can open logs, a shell inside a container, and start, stop, or restart one. Sessions opened from a container are not restored on the next launch.
- Waitlight checks for an update once a day, and you can check from the menu. Updates come from GitHub Releases. Each one is EdDSA-signed and must carry the same Developer ID as the app you have. If an agent is mid-turn, it asks before restarting.

#### Panes

- `⌘[ ⌘]` or `⌘⌥←↑↓→` move between panes.
- `⌘⌃←↑↓→` resize, `⌃⌘=` equalizes, `⌘W` closes the pane.
- A new pane starts in the current folder. Layouts are restored on relaunch.

#### Find and scrollback

- `↩ ⇧↩` or `⌘G ⇧⌘G` step through matches, with a match counter.
- `⌘E` searches for the current selection.
- `⌘↑ ⌘↓` jump between prompts. The scroll indicator can be dragged.

#### Agents

- In a session, the toolbar shows which agent you are on (2/5, say), with arrows to the previous and the next.
- A task reaches the agent through {prompt} in its prompt arguments. Most built-in agents have it set (all but Amp, Crush, and Aider); a custom agent is offered in the bar once you fill it in.
- `⌘⇧1`…`⌘⇧9` open a new session, in the order shown in Manage Agents, counting only installed agents.
- A custom agent takes separate arguments for a new conversation, resuming one, and continuing the latest. {id} in them becomes the conversation id.
- Waitlight looks for the commands on the PATH of your login shell, so ones installed through nvm or in ~/.local/bin are found. It checks again when you switch back to it, so an agent you just installed elsewhere shows up too.

#### Servers

- The server editor shows a command preview and a Test Connection button, which reports the OS, whether tmux or zellij is installed, and existing sessions.
- You can force tmux or zellij per server, or attach to an existing session.
- Right-click an entry from ~/.ssh/config to remove it from the list. It is only hidden in Waitlight; the file is not edited, and hidden entries can be restored.
- The ssh integration from Ghostty works as usual (ssh-terminfo, ssh-env).

#### Performance panel

- CPU (per core, plus load average on servers), memory, GPU (Apple GPU, or NVIDIA through nvidia-smi on servers), network, and disk.
- Session usage: the process tree of each session on the Mac, the busiest processes on a server.
- Choose which monitors to show and how often they refresh (1, 2, or 5 seconds) from the panel menu.
- The panel is closed by default. While it is closed or the window is hidden, nothing is sampled and no connection is kept.

#### Settings

- Terminal: color theme (every theme bundled with Ghostty plus your own, with swatches and search), font, size, line height, cursor style and blink, padding.
- Also Option as Alt, copy on select, and hiding the mouse while typing. Changes preview live, are layered on top of your Ghostty config, and apply to every terminal immediately. The file is never modified.
- Chinese, Japanese, and Korean text uses PingFang SC by default, so weights and punctuation stay consistent; you can pick another font.
- Appearance: background opacity from 30 to 100%, and blur. Text stays opaque. This applies inside Waitlight only, and Waitlight is always dark.

## Things you might ask.

### What is Waitlight?

Waitlight is a native macOS app for running multiple AI coding agents (Claude Code, Codex, Gemini and more) side by side, locally or over SSH, with one sidebar that shows which agent needs you. Every pane is a real Ghostty terminal.

### What happened to AgentDeck?

This is it. Waitlight was called AgentDeck before 0.10 and was renamed because too many other projects share that name. If you have it installed, update from inside the app; your sessions, servers and settings carry over.

### Which agents does it work with?

Claude Code, Codex, Gemini, Grok, opencode, Qwen Code, Cursor CLI, Copilot CLI, Droid, Amp, Crush and Aider are built in, and any other CLI can be added. Waitlight detects which ones you have installed and can install the rest from inside the app.

### Is it free and open source?

Yes. It is free and MIT licensed, with the source on GitHub at github.com/CassianFlorin/Waitlight.

### What do I need, and how do I install it?

macOS 14 or later on Apple silicon. Install it with Homebrew, `brew install --cask cassianflorin/tap/waitlight`, or download the DMG from GitHub Releases. It is signed and notarized by Apple, and updates itself.

### Do I need to install anything on my servers?

No. Waitlight uses plain SSH, and the hosts in `~/.ssh/config` just work. If the server has tmux or zellij, Waitlight uses it, so after a dropped connection it reattaches with the agent still running. The performance panel reads Linux's /proc over the same SSH connection.

### How is it different from tabs in iTerm or tmux?

The terminal is still a terminal (Ghostty). What Waitlight adds is each agent's state: which one is working, which is stuck on a permission prompt, which has finished its turn. `⌘⇧J` jumps to the next one waiting for you, the Agent overview shows them all on one screen where you can reply and hand out tasks, and agents return to the same conversation after a relaunch.

### Does it change my agent settings?

No. Claude Code's hooks are passed with `--settings` at launch, without touching your settings files. The status hooks for Codex and Grok are opt-in; turning one on writes a single file of Waitlight's own, and turning it off deletes it.

### Does it collect any data?

No. There is no analytics or telemetry. The only connection Waitlight makes on its own is checking GitHub Releases for updates.

## Take it if it fits.

Built for one person's workflow, and open-sourced in case it fits yours. Download a signed build from Releases, or build it yourself.

- **Agents**: 12 mainstream CLIs built in, listed once installed
- **System**: macOS 14 or later
- **Chip**: Apple silicon only, for now
- **Remote stats**: Linux only, for now
- **License**: MIT. The terminal engine is Ghostty

You need macOS 14 or later, Xcode 16 or later, XcodeGen, and Zig (the version named by minimum_zig_version in vendor/ghostty/build.zig.zon).

```
git clone --recursive https://github.com/CassianFlorin/Waitlight.git
cd Waitlight
scripts/build-ghosttykit.sh      # builds GhosttyKit, about 5 minutes the first time
scripts/fetch-sparkle.sh         # downloads the Sparkle updater
xcodegen
open Waitlight.xcodeproj
```

The Debug configuration is ad-hoc signed, so no certificate is needed. On Xcode 26 and later the Metal compiler is a separate component; install it once:

```
xcodebuild -downloadComponent MetalToolchain
```

If Zig fails to fetch its dependencies (a 400 behind an HTTP proxy, or hash mismatch / DirNotEmpty), fetch them with curl first and build offline:

```
scripts/prefetch-zig-deps.sh
ZIG_SYSTEM_DIR=vendor/zig-deps/pkg scripts/build-ghosttykit.sh
```

For a hash mismatch after an interrupted build, run CLEAN=1 scripts/build-ghosttykit.sh.
