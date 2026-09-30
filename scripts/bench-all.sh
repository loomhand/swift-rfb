#!/bin/bash
# Runs the comparison in docs/benchmarks.md: idle and full-screen animation
# CPU/wakeups/footprint for rfb-view and royalvnc-view against x11vnc (:5901)
# and TigerVNC (:5902), then first-update latency.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT=.build/release/rfb-view
ROYAL=Benchmarks/RoyalVNCView/.build/release/royalvnc-view
WARMUP=${WARMUP:-8}
WINDOW=${WINDOW:-20}
for mode in idle full; do
  scripts/servers.sh "$mode" 30 >/dev/null
  sleep 15
  for pair in x11vnc:5901 tigervnc:5902; do
    server=${pair%:*} port=${pair#*:}
    scripts/measure.sh "$mode $server swift-rfb" "$WARMUP" "$WINDOW" -- "$SWIFT" "127.0.0.1:$port"
    scripts/measure.sh "$mode $server royalvnc" "$WARMUP" "$WINDOW" -- "$ROYAL" "127.0.0.1:$port"
  done
done
for pair in x11vnc:5901 tigervnc:5902; do
  port=${pair#*:}
  for i in 1 2 3 4 5; do
    echo "ttff ${pair%:*} swift-rfb: $("$SWIFT" "127.0.0.1:$port" --exit-after-first-frame | grep first_ | tr '\n' ' ')"
    echo "ttff ${pair%:*} royalvnc: $("$ROYAL" "127.0.0.1:$port" --exit-after-first-frame)"
  done
done
