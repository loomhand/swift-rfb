#!/bin/bash
# Starts the test servers: servers.sh [MODE] [FPS]  (MODE=idle|region|full)
# x11vnc on :5901, TigerVNC Xvnc on :5902; a password-protected x11vnc on :5903.
set -euo pipefail
MODE=${1:-region}
FPS=${2:-30}
IMAGE=swift-rfb-scene  # docker build -t swift-rfb-scene docker
start() {
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" -p "$2:5900" -e SERVER="$3" -e MODE="$MODE" -e FPS="$FPS" -e PASSWORD="${4:-}" "$IMAGE" >/dev/null
}
start rfb-x11 5901 x11vnc
start rfb-tiger 5902 tigervnc
start rfb-x11-auth 5903 x11vnc secret
for port in 5901 5902 5903; do
  for _ in $(seq 1 100); do
    banner=$( (nc -w 1 127.0.0.1 "$port" </dev/null 2>/dev/null || true) | head -c 3)
    [ "$banner" = RFB ] && break
    sleep 0.2
  done
  echo "port $port: ${banner:-not ready}"
done
