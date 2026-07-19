#!/usr/bin/env bash
set -euo pipefail

: "${TARI_WALLET:?Set TARI_WALLET to your Tari wallet address}"
TARI_POOL="${TARI_POOL:-taric29-ca.luckypool.io:3111}"
TARI_WORKER="${TARI_WORKER:-$(hostname)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$ROOT/tari_c29_pool_miner" \
  --pool "$TARI_POOL" \
  --wallet "$TARI_WALLET" \
  --worker "$TARI_WORKER" \
  "$@"
