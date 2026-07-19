#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arch in sm_86 sm_89 sm_120; do
    "$ROOT/build_solver.sh" "$arch"
    "$ROOT/build_pool_miner.sh" "$arch"
done

echo "All Linux GPU backends built successfully."
