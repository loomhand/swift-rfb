#!/bin/bash
# SERVER=x11vnc|tigervnc  MODE=idle|region|full  FPS=30  GEOMETRY=1280x800  PASSWORD=
# DELAY_MS=N adds N ms each way with netem (needs --cap-add NET_ADMIN).
set -euo pipefail
if [ -n "${DELAY_MS:-}" ]; then
  ip link add ifb0 type ifb
  ip link set ifb0 up
  tc qdisc add dev eth0 root netem delay "${DELAY_MS}ms" limit 100000
  tc qdisc add dev eth0 handle ffff: ingress
  tc filter add dev eth0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
  tc qdisc add dev ifb0 root netem delay "${DELAY_MS}ms" limit 100000
fi
SERVER=${SERVER:-x11vnc}
MODE=${MODE:-region}
FPS=${FPS:-30}
GEOMETRY=${GEOMETRY:-1280x800}
W=${GEOMETRY%x*}
H=${GEOMETRY#*x}
export DISPLAY=:0 SDL_AUDIODRIVER=dummy
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

convert -size "${W}x${H}" -seed 7 plasma:fractal -blur 0x1 \
  \( -size "$((W / 2))x${H}" xc:white -font DejaVu-Sans -pointsize 14 -fill black \
     -annotate +12+24 "$(for i in $(seq 1 60); do printf 'line %02d  The quick brown fox jumps over the lazy dog 0123456789\\n' "$i"; done)" \) \
  -gravity east -composite /tmp/pattern.png

if [ "$SERVER" = tigervnc ]; then
  sec=None
  if [ -n "${PASSWORD:-}" ]; then
    printf '%s\n' "$PASSWORD" | vncpasswd -f >/tmp/passwd
    sec=VncAuth
  fi
  Xvnc :0 -geometry "$GEOMETRY" -depth 24 -rfbport 5900 -SecurityTypes "$sec" -PasswordFile /tmp/passwd -AlwaysShared -AcceptSetDesktopSize=0 >/tmp/xvnc.log 2>&1 &
else
  Xvfb :0 -screen 0 "${GEOMETRY}x24" -nolisten tcp >/tmp/xvfb.log 2>&1 &
fi
for _ in $(seq 1 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done

display -window root /tmp/pattern.png || true

case "$MODE" in
  region) ffplay -loglevel quiet -an -noborder -left 880 -top 480 -f lavfi -i "testsrc2=size=320x240:rate=$FPS" & ;;
  full) ffplay -loglevel quiet -an -noborder -left 0 -top 0 -f lavfi -i "testsrc2=size=${W}x${H}:rate=$FPS" & ;;
esac

if [ "$SERVER" = tigervnc ]; then
  wait
else
  auth=(-nopw)
  [ -n "${PASSWORD:-}" ] && auth=(-passwd "$PASSWORD")
  exec x11vnc -display :0 -rfbport 5900 -forever -shared -noipv6 ${X11VNC_ARGS:--quiet} "${auth[@]}"
fi
