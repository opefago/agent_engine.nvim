#!/usr/bin/env bash
# Install agent_engine.nvim into the Lazy.nvim plugin directory.
set -euo pipefail

REPO_URL="${1:-https://github.com/opefago/agent_engine.nvim.git}"
NVIM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
NVIM_CONFIG="${NVIM_APPNAME:+$HOME/.config/$NVIM_APPNAME}"
NVIM_CONFIG="${NVIM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nvim}"
DEST="${AGENT_ENGINE_DEST:-$NVIM_DATA/lazy/agent_engine.nvim}"
SPEC_DIR="$NVIM_CONFIG/lua/plugins"
SPEC_FILE="$SPEC_DIR/agent_engine.lua"

already_installed=0
if [[ -d "$DEST/.git" ]]; then
  echo "Already installed at: $DEST"
  echo "Update with: git -C \"$DEST\" pull"
  already_installed=1
else
  mkdir -p "$(dirname "$DEST")"
  echo "Cloning $REPO_URL"
  echo "  -> $DEST"
  git clone --depth 1 "$REPO_URL" "$DEST"
fi

# Auto-register the Lazy.nvim plugin spec so users don't have to add it by hand.
# Only write it if lazy.nvim's spec dir exists and no spec for this plugin is
# already present (never clobber a user's existing customization).
if [[ -d "$NVIM_CONFIG/lua/plugins" || -f "$NVIM_CONFIG/init.lua" ]] && [[ ! -f "$SPEC_FILE" ]]; then
  mkdir -p "$SPEC_DIR"
  cat >"$SPEC_FILE" <<'LUA'
return {
  "opefago/agent_engine.nvim",
  lazy = false,
  opts = {
    default_cli = "cursor",
    review_style = "ghost",
  },
  config = function(_, opts)
    require("agent_engine").setup(opts)
  end,
}
LUA
  echo "Wrote Lazy.nvim spec -> $SPEC_FILE"
  spec_written=1
else
  spec_written=0
fi

cat <<EOF

Installed at: $DEST
EOF

if [[ "${spec_written:-0}" -eq 1 ]]; then
  cat <<'EOF'
Lazy.nvim spec created automatically. Just run :Lazy sync and :AgentChat.
EOF
else
  cat <<'EOF'
Could not auto-detect your Lazy.nvim config (or a spec already exists).
Add this manually to lua/plugins/agent_engine.lua:

return {
  "opefago/agent_engine.nvim",
  lazy = false,
  opts = {
    default_cli = "cursor",
    review_style = "ghost",
  },
  config = function(_, opts)
    require("agent_engine").setup(opts)
  end,
}

Then run :Lazy sync and :AgentChat
EOF
fi

echo
echo "Read DISCLAIMER.md before use: agent CLIs can modify your files."
