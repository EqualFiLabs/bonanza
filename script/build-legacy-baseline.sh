#!/usr/bin/env bash
set -euo pipefail
# Compile the exact pre-FIDDY main contracts without importing new source.
cd "$(dirname "$0")/.."
baseline=87f5e973cc3e7db01d04a243116fc448d149478f
mkdir -p .legacy-build
git archive "$baseline" src foundry.toml | tar -x -C .legacy-build
if [ ! -e .legacy-build/lib ]; then ln -s ../lib .legacy-build/lib; fi
forge build --root .legacy-build --out ../out-legacy --skip test --skip script
