#!/usr/bin/env bash
# Run Plenary busted tests headlessly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLENARY_DIR="${PLENARY_DIR:-/tmp/plenary.nvim}"

if [[ ! -d "$PLENARY_DIR/.git" ]]; then
  echo "Cloning plenary.nvim -> $PLENARY_DIR"
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git "$PLENARY_DIR"
fi

export PLENARY_DIR
cd "$ROOT"

nvim --headless \
  -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })" \
  -c "qa!"
