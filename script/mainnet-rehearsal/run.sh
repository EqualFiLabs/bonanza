#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
# Source only the explicitly designated RPC environment, never deployment keys.
set -a
source "${LOTTERY_RPC_ENV:-$HOME/.openclaw/workspace/.rpc}"
set +a
exec python3 script/mainnet-rehearsal/rehearse.py "$@"
