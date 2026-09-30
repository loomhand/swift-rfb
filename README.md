# swift-rfb

A small, event-driven RFB (VNC) client for macOS with a Metal renderer. It does
no work while the remote screen is still: no timers, no polling, no display
link ticks. Decoders write straight into page-aligned memory that the GPU
reads as a texture, so an update costs one decode and one draw.

- `RFB` — protocol, decoders, input mapping. Foundation, Network, zlib,
  CommonCrypto, ImageIO; no AppKit.
- `RFBMetal` — `RFBRenderer` (Metal, platform-neutral) and `RFBView`
  (AppKit view with pointer, keyboard and cursor handling).
- `rfb-view` — example viewer. `rfb-bench` — live/replay benchmark.

Requires Swift 6, macOS 15 (iOS 18 for the platform-neutral parts). No
third-party dependencies.

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

### Update pacing

With `requestsOnConsume` (the default) the client asks for the next
incremental update only after `framebufferConsumed()`, which `RFBView` calls
when the GPU has finished reading the frame. An idle or hidden view therefore
costs nothing on either side. When the server offers ContinuousUpdates (and
`continuousUpdates` is on) the client enables them instead and answers the
server's fences. Headless users set `requestsOnConsume = false`.

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
  notify (TigerVNC). libvncserver 0.9.14 (x11vnc) drops clients that send it
  a provide, so those servers get Latin-1.

`Configuration` selects encodings, JPEG quality (`nil` keeps Tight lossless),
compression level, password, shared flag, continuous updates, pacing and
statistics collection.

## Building and testing

Command Line Tools installs that carry stale files from an older release
break Foundation imports; `scripts/toolchain.sh` masks them without touching
`/Library`.

```sh
source scripts/toolchain.sh
swift build -c release --product rfb-view
scripts/test.sh                     # swift-testing suite, run as an executable
scripts/servers.sh region           # x11vnc :5901, TigerVNC :5902, x11vnc+password :5903
.build/release/rfb-view 127.0.0.1:5901 [--control] [--password PW]
```

The tests cover the handshake state machine, every decoder against encoded
fixtures, server recordings from x11vnc and TigerVNC (every lossless encoding
must rebuild the same framebuffer as raw), pacing, fences, continuous
updates, clipboard and the key map. Measurements are in
[docs/benchmarks.md](docs/benchmarks.md).
