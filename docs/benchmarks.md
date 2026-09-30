# Benchmarks

All runs are on 2026-09-30, on an Apple M2 Max with macOS 15.7.7 and Swift 6.2.3 (Command Line Tools), using
release builds. The servers run in Docker Desktop (arm64, 12 CPUs). They come from `docker/`, started by
`scripts/servers.sh`, and run at 1280x800x24:

- x11vnc 0.9.16 (libvncserver 0.9.14) on Xvfb, `:5901`
- TigerVNC Xvnc 1.12.0, `:5902`

Both servers draw the same scene: a plasma image with a text column. Three modes set what moves on it:

| mode | what changes |
|---|---|
| `idle` | nothing |
| `region` | a 320x240 ffplay `testsrc2` window at 30 fps |
| `full` | a 1280x800 `testsrc2` at 30 fps, so the whole screen changes every frame |

The baseline is RoyalVNCKit 1.1.0. This is the revision cocoonbox pins. It runs in its own
`VNCCAFramebufferView`, through `Benchmarks/RoyalVNCView` (`royalvnc-view`), and asks for its default
encodings: tight, zrle, zlib and hextile. `rfb-view` runs with the default `RFBClient.Configuration`:
tight, zrle, hextile, copyrect and raw, JPEG quality 8, and continuous updates when the server offers
them. Each viewer shows the whole desktop in a 1280x800-point window on a Retina display.

## How the numbers are taken

`scripts/measure.sh` starts a viewer and waits 8 s. It then samples the process for 20 s with two
independent tools:

- `scripts/procstat.swift` reads `proc_pidinfo(PROC_PIDTASKINFO)` and `proc_pid_rusage(RUSAGE_INFO_V4)`.
  It reports CPU time (with the system share), context switches, package idle wakeups, interrupt
  wakeups and `phys_footprint`, as deltas over the window.
- `top -l 2 -s 20 -stats pid,cpu,idlew,mem` is the second signal, from the second sample.

`rss_mb` comes from `ps`. `scripts/bench-all.sh` runs the whole matrix, and its raw output is kept in
`.build/bench-all.txt`.

To calibrate the counters: a `python3` loop running `sleep(0.01)` shows about 91 context switches/s and
87 interrupt wakeups/s. Under Docker load it shows only about 5 package idle wakeups/s. So on this
machine, "wakeups" in the RoyalVNC sense (about 100/s) show up as **interrupt wakeups**. Package idle
wakeups stay low because the CPU is rarely idle while the containers run.

## Idle screen

| server | viewer | CPU % (procstat / top) | ctx switches/s | interrupt wakeups/s | idle wakeups/s (procstat / top IDLEW) | footprint MB |
|---|---|---|---|---|---|---|
| x11vnc | **swift-rfb** | **0.01 / 0.0** | **1.3** | **0.4** | 0.0 / 0 | 30.7 |
| x11vnc | RoyalVNCKit | 0.47 / 0.4 | 295.8 | 93.5 | 1.8 / 45 | 26.0 |
| TigerVNC | **swift-rfb** | **0.01 / 0.0** | **1.1** | **0.4** | 0.0 / 0 | 31.3 |
| TigerVNC | RoyalVNCKit | 0.91 / 0.8 | 351.2 | 93.5 | 4.1 / 131 | 21.8 |

RoyalVNCKit polls its send queue with `Task.sleep(0.01)`, which gives the 93 wakeups/s and 300–350
context switches/s. swift-rfb waits in one socket read, keeps its display link paused and has no
timers. The one remaining wakeup every ~2.5 s is not caused by the viewer.

## Full-screen animation (1280x800, 30 fps)

| server | viewer | CPU % (procstat / top) | system CPU % | ctx switches/s | interrupt wakeups/s | footprint MB |
|---|---|---|---|---|---|---|
| x11vnc | **swift-rfb** | **9.14 / 8.6** | 2.36 | 1 399 | 116.7 | 40.2 |
| x11vnc | RoyalVNCKit | 31.02 / 29.2 | 15.61 | 31 755 | 86.7 | 37.4 |
| TigerVNC | **swift-rfb** | **11.62 / 11.0** | 2.53 | 1 424 | 121.1 | 38.9 |
| TigerVNC | RoyalVNCKit | 68.02 / 64.3 | 36.54 | 88 488 | 102.4 | 24.3 |

x11vnc delivers about 35–40 updates/s here. TigerVNC uses continuous updates at about 30–55 updates/s.

**Where swift-rfb's CPU goes.** A headless `rfb-bench live` with the same server and settings uses the
same CPU as the viewer: 8.7% on x11vnc and 10.3% on TigerVNC with JPEG, and 6.0% for either with JPEG
off. So Metal rendering and presenting cost well under 1%. The rest is decoding, plus the network path:
socket reads and thread hops, 2.3% system time.

JPEG makes the stream smaller but costs more client CPU than lossless Tight: +2.5 points on x11vnc.
ImageIO's per-rectangle cost dominates this.

## First frame

This is the median of five runs at `full` mode, measured from the start of the TCP connect.

- **first update** is when the first update with pixels has been decoded. `royalvnc-view` prints its
  number when that update is handed to its view, so the two first-update columns compare like for like.
- **presented** is the Metal presented-handler time of the first frame with content (swift-rfb only).

| server | swift-rfb first update | swift-rfb presented | RoyalVNCKit first update |
|---|---|---|---|
| x11vnc (4 runs) | 242 ms | 250 ms | 255 ms |
| TigerVNC | 47 ms | 55 ms | 52 ms |

On x11vnc the protocol banner alone takes 100–290 ms (seen with a raw socket), so that server bounds
the number.

Two effects add noise:
- NWConnection takes about 36 ms to reach `.ready` on loopback, for both clients.
- x11vnc sometimes stalls new clients for 1.7–2.5 s while it is under load or just after it starts.
  Both clients hit this: RoyalVNCKit once measured 2 057 ms, swift-rfb 1 719 ms. These runs are
  outliers and are left out of the medians.

## Decode throughput

`rfb-bench live --record` captured 8 s of the `full` scene from each server, for each encoding. The
captures used `--no-continuous` and immediate requests. `rfb-bench replay` then feeds each capture
through the whole client (handshake, parsing, decoders, statistics) as fast as it can. The table shows
the best of 3 runs.

| server | encoding | wire MB | updates | frames/s | wire MB/s | decode Mpx/s |
|---|---|---|---|---|---|---|
| x11vnc | raw | 117.2 | 136 | 6 455 | 5 562 | 1 430 |
| x11vnc | hextile | 57.3 | 328 | 6 648 | 1 161 | 1 195 |
| x11vnc | zrle | 28.8 | 262 | 1 281 | 141 | 274 |
| x11vnc | tight (lossless) | 30.5 | 318 | 1 986 | 191 | 301 |
| x11vnc | tight + JPEG q8 | 21.3 | 302 | 710 | 50 | 112 |
| TigerVNC | raw | 155.4 | 256 | 7 490 | 4 546 | 1 255 |
| TigerVNC | hextile | 69.3 | 245 | 4 713 | 1 332 | 753 |
| TigerVNC | zrle | 31.3 | 256 | 1 513 | 185 | 233 |
| TigerVNC | tight (lossless) | 31.8 | 257 | 1 458 | 181 | 223 |
| TigerVNC | tight + JPEG q8 | 27.1 | 445 | 740 | 45 | 70 |

A full 1280x800 frame is 1.02 Mpx. Lossless Tight and ZRLE decode 220–300 full frames/s on one core.

Profiles (`sample`) put zlib at 55–80% of lossless decode time. The rest is pixel conversion, which
reads 4 bytes and shifts per pixel. For JPEG, AppleJPEG's Huffman decoding is the largest part, and
ImageIO/CoreGraphics per-image overhead is about 35%.

## Negotiated encodings

These come from `rfb-bench live` statistics and the verbose x11vnc log.

| server | default list picks | pseudo-encodings seen | continuous updates / fence | extended clipboard | QEMU key event |
|---|---|---|---|---|---|
| x11vnc 0.9.16 | tight (JPEG with a quality level) | ExtendedDesktopSize, RichCursor, PointerPos, LastRect | no / no | caps `text, request, peek, provide` (no notify) | no |
| TigerVNC 1.12 | tight | ExtendedDesktopSize, RichCursor, QEMU extended key | yes / yes (about 2 fences per update) | yes, with notify | yes |

Both servers honour the client's first choice when zrle, hextile or raw is listed first.

## Steady-state memory

| state | swift-rfb footprint | RoyalVNCKit footprint |
|---|---|---|
| idle | 31 MB | 22–26 MB |
| full animation | 39–40 MB | 24–37 MB |

`rss_mb` is 76–82 MB for both. `footprint` shows where swift-rfb's memory goes:
- 8 MB of IOSurface for the two 1280x800 drawables
- 4.3 MB for the framebuffer. It is `mmap`ed memory that Metal wraps without copying; a separate
  footprint test showed it is counted once.
- about 6.5 MB of malloc, mostly AppKit

Allocations stay flat in steady state:
- The reader buffer and the decoder scratch only grow.
- There are no per-update framebuffer copies.
- Each update allocates only the `Data` chunks that Network.framework hands over and, with JPEG, the
  ImageIO objects.

## Functional checks against the servers

- **Pointer.** `rfb-bench input --move 123,456 --click` puts the X pointer at x:123 y:456 on both
  servers, checked with `xdotool getmouselocation`.
- **Keyboard.**
  - `rfb-bench input --type 'Hi! é€'` arrives in `xev` as `H i exclam space eacute U20AC` on both
    servers. x11vnc adds its own Shift for `H`.
  - `--keys 0x00,0x0B,0x12,0x7E,0x24,0x38,0x7A` (macOS key codes for a, b, 1, Up, Return, Shift and F1)
    arrives as X keycodes `38 56 10 111 36 50 67` on TigerVNC, over QEMU extended key events with XT
    scancodes. On x11vnc it arrives as the same keysyms.
- **VNC Authentication.** Against x11vnc with `-passwd secret`, the right password connects and a wrong
  one fails.
- **Clipboard, TigerVNC.** UTF-8 works both ways through the extended clipboard:
  - `setClipboard("from client ✓ ü")` shows up in the X CLIPBOARD and PRIMARY selections.
  - `xclip` "from server ☃ é" arrives as a `.clipboard` event.
- **Clipboard, x11vnc.** Relaying did not work at all in this container, even for a plain RFB 3.8
  client in Python that uses only legacy cut text. Its verbose log shows that libvncserver 0.9.14
  closes the connection ("zlib inflation error") on any extended-clipboard provide from a client,
  including a standard `zlib.compress` payload. swift-rfb therefore sends Latin-1 cut text to servers
  whose caps lack notify.
