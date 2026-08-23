# Disclaimer

**agent_engine.nvim** is experimental software provided **as-is**, without warranty of any kind.

## Third-party agent CLIs

This plugin does **not** include an AI model or agent runtime. It launches **external programs** from your `PATH` (Cursor Agent, Claude Code, GitHub Copilot CLI, Aider, etc.). You are responsible for:

- Installing, authenticating, and complying with each CLI’s terms of service
- Understanding what data those tools send to remote services
- Reviewing file changes before accepting them (use ghost review; do not blindly accept)

## File system access

Agent CLIs can **read, create, modify, and delete files** in your workspace. Defaults that affect safety:

| Setting | Default | Meaning |
| --- | --- | --- |
| `trust` | `true` | Cursor agent receives `--trust` (workspace trusted for tool use) |
| Copilot dialect | `--allow-all-tools` | Copilot runs with broad tool permissions when that backend is selected |
| `force` | `false` | When `true`, passes `--force` to supported CLIs |

Review your `require("agent_engine").setup({ ... })` options before use on sensitive repositories.

## No endorsement

Mention of Cursor, Anthropic, GitHub, OpenAI, or other vendors does not imply endorsement. Trademarks belong to their respective owners.

## Security reporting

If you find a security issue in **this plugin’s Lua code**, please open a private security advisory on GitHub or contact the maintainer directly. Issues in upstream CLIs should be reported to those projects.

## Alpha software

APIs, defaults, and behavior may change without notice until v1.0. Pin a git tag or commit for production dotfiles.
