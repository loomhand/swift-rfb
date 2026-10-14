# swift-rfb

A small, event-driven RFB (VNC) client for macOS with a Metal renderer. It does
no work while the remote screen is still: no timers, no polling, no display
link ticks. Decoders write straight into page-aligned memory that the GPU
reads as a texture, so an update costs one decode and one draw.

**Documentation: [loomhand.github.io/swift-rfb](https://loomhand.github.io/swift-rfb/)** (source in [`docs/`](docs/)).

- `RFB` — protocol, decoders, input mapping. Foundation, Network, zlib,
  CommonCrypto, ImageIO; no AppKit.
- `RFBMetal` — `RFBRenderer` (Metal, platform-neutral) and `RFBView`
  (AppKit view with pointer, keyboard and cursor handling).
- `rfb-view` — example viewer. `rfb-bench` — live/replay benchmark.

Requires Swift 6, macOS 15 (iOS 18 for the platform-neutral parts). No
third-party dependencies.

## Architecture

```
RFB server (x11vnc, TigerVNC, ...)
   │ ▲
   │ │ input, update requests
   ▼ │
RFBTransport ── RFBTCPTransport (Network.framework) or RFBPipe (any byte stream)
   │ ▲
   ▼ │
RFBClient.run ── handshake → message reader → decoders (Raw, CopyRect, Hextile, ZRLE, Tight)
   │                                               │ write in place
   │                                               ▼
   │                                          RFBFramebuffer (page-aligned BGRX)
   │ RFBEvent (connected, resized, updated, cursor, clipboard, ...)
   ▼
RFBView ── RFBRenderer: Metal texture over the framebuffer memory, one draw per change
   │
   └─► framebufferConsumed() once the GPU has read the frame → next update request
```

## Install

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/loomhand/swift-rfb.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "RFB", package: "swift-rfb"),
        .product(name: "RFBMetal", package: "swift-rfb"),
    ]),
]
```

## Usage

```swift
import RFB
import RFBMetal

let view = RFBView()!                        // add it to a window
let transport = RFBTCPTransport(host: "127.0.0.1", port: 5900)
let client = RFBClient(transport: transport)
view.client = client                         // input and update pacing
view.isInputEnabled = false                  // view only; true to take control

Task {
    try await transport.connect()
    try await client.run(view.eventHandler)  // returns when the session ends
}
```

`run` performs the handshake and processes server messages on the calling
task until the connection closes; cancel the task to end the session.

### Any byte stream

`RFBTransport` is four members: `receive(expecting:)`, `send(_:)`, `close()`
and an optional `executor`. `RFBPipe` adapts any other stream, for example a
gRPC bidi call:

```swift
let pipe = RFBPipe()
let client = RFBClient(transport: pipe)
Task {
    try await session.screen { writer in
        for await chunk in pipe.outbound { try await writer.write(frame(chunk)) }
    } onResponse: { response in
        for try await message in response.messages { await pipe.deliver(message.data) }
        pipe.finish()
    }
}
try await client.run(view.eventHandler)
```

`deliver` suspends while more than `bufferLimit` bytes wait to be decoded,
so a slow client applies backpressure to the stream.

### Events

`RFBEvent` arrives on the session task:

| event | meaning |
|---|---|
| `connected(RFBServerInfo)` | handshake done: name, size, protocol version, security type |
| `resized(RFBFramebuffer)` | a new framebuffer; the previous one is no longer written |
| `updated(RFBFramebuffer, dirty:)` | one FramebufferUpdate decoded; `dirty` bounds its rectangles |
| `cursor(RFBCursor?)` | new remote cursor shape (premultiplied BGRA), `nil` hides it |
| `pointer(x:y:)` | the server moved the pointer |
| `clipboard(String)` | server clipboard text |
| `desktopName(String)`, `bell` | |

`RFBFramebuffer` is 32bpp BGRX with 256-byte aligned rows in page-aligned,
page-multiple memory; `makeImage()` copies it into a `CGImage`.

### Input

```swift
client.pointer(x: 10, y: 20, buttons: [.left])
client.key(RFBKeyMap.returnKey, down: true)          // keysym
client.key(keysym, down: true, scancode: RFBKeyMap.scancode(keyCode: 0x24))
client.type("hello\n")
client.setClipboard("text")
```

`RFBView` does this for AppKit events: buttons, scroll wheel as buttons 4–7,
key codes and characters mapped to X11 keysyms (modifiers, arrows, function
and keypad keys, dead keys), XT scancodes for QEMU's extended key event, and
releases held keys and buttons when it loses focus. `RFBKeyMap` exposes the
mapping for other front ends.

It also offers `onFirstFrame`, `onInput` (a key or button press was
sent) and `onPresent` (a drawn frame reached the display) for latency
measurements, plus `snapshot()`, `contentRect` and point conversion both ways.

### Update pacing

When the server offers ContinuousUpdates (TigerVNC does, x11vnc does not)
and `continuousUpdates` is on, the client enables them, answers the server's
fences and sends no requests.

Otherwise the client sends one incremental request per update. While updates
keep arriving it also sends one every `requestInterval` (33 ms). The server
then has a request waiting whenever the screen changes, so a high-latency
path is not capped at one update per round trip. The timer stops a second
after the last update, so an idle screen costs nothing.

With `requestsOnConsume` (the default), requests pause while `maxUndrawn`
(2) delivered updates are waiting for `framebufferConsumed()`. `RFBView` calls
it once the GPU has read the frame, so a hidden view stops the server as
well. Headless users set `requestsOnConsume = false`.

### Handshake round trips

The last security step and ClientInit go out in one write, together with
SetPixelFormat, SetEncodings and the first update request (for the largest
rectangle, which the server clips). This write goes out without waiting for
SecurityResult or ServerInit, so the first update follows ServerInit in the
same flight. `eagerHandshake` goes further and writes the whole client side
before the server's banner: no client round trip at all. Use it only for a
server known to speak RFB 3.8 with security None (x11vnc -nopw, TigerVNC
SecurityTypes=None); other servers fail the session.

## Protocol support

- RFB 3.8 with 3.7 and 3.3 fallback; security None and VNC Authentication;
  shared ClientInit.
- Encodings: Raw, CopyRect, Hextile, ZRLE, Tight (fill, copy, palette,
  gradient, JPEG, four zlib streams).
- Pseudo-encodings: DesktopSize, ExtendedDesktopSize, LastRect, Cursor,
  PointerPos, DesktopName, QEMU extended key event, ContinuousUpdates, Fence,
  Tight JPEG quality and compression level, Extended Clipboard (UTF-8).
- Clipboard: Latin-1 ServerCutText/ClientCutText, and UTF-8 through the
  extended clipboard notify/request/provide flow with servers that offer
  notify (TigerVNC). libvncserver 0.9.14 (x11vnc 0.9.16) closes the
  connection when a client sends it an extended-clipboard provide ("zlib
  inflation error", even for a standard zlib payload). Its caps lack notify,
  so swift-rfb sends such servers Latin-1 ClientCutText instead.

`Configuration` selects encodings, JPEG quality (`nil` keeps Tight lossless),
compression level, password, shared flag, eager handshake, continuous
updates, request pacing and statistics collection.

## Building and testing

Command Line Tools installs that carry stale files from an older release
break Foundation imports; `scripts/toolchain.sh` masks them without touching
`/Library`.

```sh
make build                          # debug build of every target
make release                        # release rfb-view and rfb-bench
make test                           # swift-testing suite, run as an executable
make help                           # list the targets
scripts/servers.sh region           # x11vnc :5901, TigerVNC :5902, x11vnc+password :5903
.build/release/rfb-view 127.0.0.1:5901 [--control] [--password PW]
```

The make targets source `scripts/toolchain.sh` themselves. Without make:

```sh
source scripts/toolchain.sh
swift build -c release --product rfb-view
scripts/test.sh
```

The tests cover the handshake state machine, every decoder against encoded
fixtures, server recordings from x11vnc and TigerVNC (every lossless encoding
must rebuild the same framebuffer as raw), pacing, fences, continuous
updates, clipboard and the key map. Measurements are in
[docs/benchmarks.md](docs/benchmarks.md).

`scripts/servers.sh` runs the `swift-rfb-scene` image; build it from
`docker/` first (`docker build -t swift-rfb-scene docker`).

## Documentation

- [Benchmarks](docs/benchmarks.md): CPU, wakeups, first-frame latency,
  high-latency pacing and decode throughput against RoyalVNCKit, with the
  method to reproduce them.

## Related projects

- [loomhand/cocoonbox](https://github.com/loomhand/cocoonbox): persistent
  cloud computers; its macOS client uses swift-rfb to show the remote desktop.
- [loomhand/cua](https://github.com/loomhand/cua): open-source computer-use
  drivers, cross-OS fleets and benchmarks.
- [cocoonstack/cocoon](https://github.com/cocoonstack/cocoon): MicroVM engine
  on Cloud Hypervisor.

## License

[MIT](LICENSE)
