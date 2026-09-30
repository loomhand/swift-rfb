#!/bin/bash
# wan-pacing.sh MODE: updates/s on x11vnc (:5901) and TigerVNC (:5902) under
# the servers' netem delay, for one request per update, cocoonbox's
# UpdatePump (Benchmarks/PumpProxy on :5911) and swift-rfb's pacer.
set -euo pipefail
cd "$(dirname "$0")/.."
BENCH=.build/release/rfb-bench
SECONDS_=${SECONDS_:-15}
Benchmarks/PumpProxy/.build/release/pump-proxy 5911 5901 >/tmp/pump-proxy.log 2>&1 &
PROXY=$!
trap 'kill $PROXY 2>/dev/null' EXIT
sleep 1
run() { echo "$1: $("$BENCH" live "$2" --seconds "$SECONDS_" --eager "${@:3}" | grep '^==' | sed 's/.*: //')"; }
run "x11vnc one request per update" 127.0.0.1:5901 --interval 0
run "x11vnc UpdatePump (proxy)" 127.0.0.1:5911 --interval 0
run "x11vnc swift-rfb pacer 33 ms" 127.0.0.1:5901
run "tigervnc continuous updates" 127.0.0.1:5902
run "tigervnc no CU, one request per update" 127.0.0.1:5902 --no-continuous --interval 0
run "tigervnc no CU, pacer 33 ms" 127.0.0.1:5902 --no-continuous
