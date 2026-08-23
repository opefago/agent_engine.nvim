#!/usr/bin/env bash
# Install agent_engine.nvim into the Lazy.nvim plugin directory.
set -euo pipefail

REPO_URL="${1:-https://github.com/opefago/agent_engine.nvim.git}"
NVIM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
DEST="${AGENT_ENGINE_DEST:-$NVIM_DATA/lazy/agent_engine.nvim}"

if [[ -d "$DEST/.git" ]]; then
  echo "Already installed at: $DEST"
  echo "Update with: git -C \"$DEST\" pull"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
echo "Cloning $REPO_URL"
echo "  -> $DEST"
git clone --depth 1 "$REPO_URL" "$DEST"

cat <<'EOF'

Installed. Add to Lazy.nvim (lua/plugins/agent_engine.lua):

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

Read DISCLAIMER.md before use: agent CLIs can modify your files.
EOF
