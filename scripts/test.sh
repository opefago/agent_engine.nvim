#!/usr/bin/env bash
# Run Plenary busted tests headlessly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLENARY_DIR="${PLENARY_DIR:-/tmp/plenary.nvim}"
if [[ ! -d "$PLENARY_DIR" ]]; then
  PLENARY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/plenary.nvim"
fi

export PLENARY_DIR
cd "$ROOT"

nvim --headless \
  -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })" \
  -c "qa!"
