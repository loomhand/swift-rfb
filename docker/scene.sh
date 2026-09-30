#!/bin/bash
# SERVER=x11vnc|tigervnc  MODE=idle|region|full  FPS=30  GEOMETRY=1280x800  PASSWORD=
set -euo pipefail
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
