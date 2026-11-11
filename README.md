<p align="center">
  <img src="Resources/AppIcon-1024.png" alt="AgentDeck icon" width="160">
</p>

# AgentDeck

A native macOS workbench for AI coding agents, built on [libghostty](https://ghostty.org).

## Why

Coding with AI agents usually means running several at once: Claude Code in one repo, Codex in another, a third on a server. That quickly turns into a pile of terminal tabs. You keep checking which agent is still working, which one is waiting on a permission prompt, and where a conversation went after the window closed.

AgentDeck is my own terminal built for that workflow. It's one window with a sidebar of sessions, each a real Ghostty terminal running an agent or a shell, locally or over SSH:

- **See which agents need you.** Each session shows whether its agent is working, waiting for you, or finished.
- **Local and remote in one place.** Your servers sit next to your local sessions, and nothing needs to be installed on them.
- **Don't lose conversations.** Sessions, splits and agent conversations come back after a restart or a dropped connection.

It's a personal tool, open-sourced in case it fits your workflow too.

Download it from [Releases](../../releases). It requires macOS 14 or later on Apple silicon. See [docs/FEATURES.md](docs/FEATURES.md) for features and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building it yourself.

## Credits

The terminal engine is [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors (MIT).

## License

MIT. See [LICENSE](LICENSE).
