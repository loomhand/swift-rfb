#!/bin/bash
# measure.sh LABEL WARMUP SECONDS -- COMMAND...: launches COMMAND, waits
# WARMUP s, then samples it for SECONDS s with procstat and, independently,
# top (second signal), and stops it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=$1 WARMUP=$2 SECONDS_=$3
shift 4
LOG=$(mktemp)
TOPLOG=$(mktemp)
"$@" >"$LOG" 2>&1 &
PID=$!
sleep "$WARMUP"
top -l 2 -s "$SECONDS_" -pid "$PID" -stats pid,cpu,idlew,mem >"$TOPLOG" 2>/dev/null &
TOPPID=$!
STAT=$("$ROOT/.build/tools/procstat" "$PID" "$SECONDS_")
wait "$TOPPID" || true
RSS=$(ps -o rss= -p "$PID" | awk '{printf "%.1f", $1 / 1024}')
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
TOP=$(awk -v p="$PID" '$1 == p' "$TOPLOG" | tail -1 | awk '{print "cpu="$2"% idlew="$3" mem="$4}')
echo "$LABEL | $STAT rss_mb=$RSS | top: $TOP"
{ grep -E "first_|connected_ms|error|disconnected" "$LOG" || true; } | tr '\n' ' ' | sed 's/^/    /'
echo
rm -f "$LOG" "$TOPLOG"
