#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Wait until no process named $1 runs, at most $2 seconds (default 5).
# usage: scripts/wait-exit.sh Pave 5
set -euo pipefail
name="$1"
deadline=$(( $(date +%s) + ${2:-5} ))
while pgrep -qx "$name"; do
    if (( $(date +%s) >= deadline )); then
        echo "warning: $name still running after ${2:-5} s" >&2
        exit 0
    fi
    sleep 0.2
done
