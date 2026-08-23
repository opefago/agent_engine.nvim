# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `/login` slash command to authenticate with the Cursor agent CLI
- `auto_login` option (default `true`) — start login automatically when a prompt is sent while logged out, then send the prompt after auth succeeds

## [0.1.0-alpha] - 2026-08-22

### Added

- Standalone `agent_engine.nvim` repository layout
- Cursor-first agent chat panel with ghost review and multi-tab sessions
- Multi-CLI discovery (Cursor, Claude, Copilot, Codex, Gemini, Aider, Goose, tgpt)
- MCP and Cursor plugin-dir integration (Cursor dialect)
- Lua extension API and Headroom optional compression
- Plenary busted tests and GitHub Actions CI
- `scripts/install.sh` for CLI installation into Lazy.nvim path
- [DISCLAIMER.md](DISCLAIMER.md) for security and third-party CLI notice

[0.1.0-alpha]: https://github.com/opefago/agent_engine.nvim/releases/tag/v0.1.0-alpha
