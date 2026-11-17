# Contributing to AgentDeck

Thanks for taking a look. AgentDeck is a small, personal project, so the process is light. Issues and pull requests in English or Chinese are both fine (中文也可以).

## Before you start

- **Bugs:** open an issue with the bug template, including the AgentDeck version (AgentDeck → About) and your macOS version.
- **Features and bigger changes:** open an issue first, so we can agree on the approach before you spend time on it.
- **Security problems:** please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Building

You need macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Zig. The full steps and troubleshooting are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md):

```bash
git clone --recursive https://github.com/CassianFlorin/AgentDeck.git
cd AgentDeck
scripts/build-ghosttykit.sh && scripts/fetch-sparkle.sh
xcodegen && open AgentDeck.xcodeproj
```

The Debug configuration is ad-hoc signed, so no certificate is needed.

To try a change without touching the AgentDeck you use every day, start an isolated instance. It has its own workspace, hosts and caches:

```bash
AGENTDECK_HOME=/tmp/ad-test scripts/test-instance.sh
```

A Debug build can also be driven from the shell with `scripts/debug-cmd.sh` (see `Sources/App/DebugHooks.swift` for the commands).

## Where things live

| Path | What |
| --- | --- |
| `Sources/Agents/` | Agent presets (`AgentKind.swift`), install detection, hooks, conversation history |
| `Sources/Workspace/` | Sessions, panes and split trees |
| `Sources/UI/` | SwiftUI views: sidebar, Agent overview, settings |
| `Sources/Remote/` | SSH hosts, tmux / zellij |
| `Sources/Monitor/` | The performance panel |
| `Sources/Ghostty/` | The libghostty bridge |
| `site/` | The landing page, a single `index.html` with Chinese and English text side by side |

## Pull requests

- Keep a PR to one change, and describe what you checked by hand (CI only builds; there are no UI tests).
- The `Build (Debug)` check must pass before merging.
- Don't bump the version or create tags. Releases are cut by the maintainer.
- **Adding an agent preset:** only fill in arguments the CLI documents (resume, continue, start with a prompt). Leaving one empty just hides that feature for the agent, which is better than a wrong guess.
- **Landing page:** every visible string has a Chinese and an English version (`<span class="zh">` / `<span class="en">`); please update both, and check it at phone width.
- User-facing behavior changes should also update [docs/FEATURES.md](docs/FEATURES.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
