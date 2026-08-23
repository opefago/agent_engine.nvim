# Contributing

Thanks for contributing to agent_engine.nvim.

## Setup

```bash
git clone https://github.com/opefago/agent_engine.nvim.git
cd agent_engine.nvim
./scripts/test.sh
```

Requires Neovim 0.10+ and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (cloned automatically by CI; locally use your Lazy.nvim install or set `PLENARY_DIR`).

### Dogfooding in this Neovim config

`lua/plugins/agentvim-bundle.lua` loads this repo via Lazy `dir` (`~/.config/nvim/agent_engine.nvim`). Edit `lua/agent_engine/` here only — do not keep a second copy under `lua/agent_engine/`. After changes, `:AgentReload` or restart Neovim, then commit and push from this directory.


## Pull requests

1. Run `./scripts/test.sh` and `stylua lua/` before opening a PR.
2. Keep changes focused; match existing Lua style in `lua/agent_engine/`.
3. Update [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
4. Document new options in `lua/agent_engine/README.md` and `config.lua` annotations.

## Reporting issues

Include Neovim version (`nvim --version`), active agent CLI, and steps to reproduce. Do not paste API keys or private prompts.
