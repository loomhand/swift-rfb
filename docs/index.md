---
title: swift-rfb
---

# swift-rfb

A small, event-driven RFB (VNC) client for macOS with a Metal renderer. It
does no work while the remote screen is still: no timers, no polling, no
display link ticks. Decoders write straight into page-aligned memory that the
GPU reads as a texture, so an update costs one decode and one draw.

```
RFB server ◄──► RFBTransport (TCP or RFBPipe) ◄──► RFBClient.run
                                                    │ decoders write in place
                                                    ▼
                                    RFBFramebuffer ──► RFBView / RFBRenderer (Metal)
```

## Guides

- [Usage](https://github.com/loomhand/swift-rfb#usage) — connecting, any
  byte stream through `RFBPipe`, events, input and update pacing
- [Protocol support](https://github.com/loomhand/swift-rfb#protocol-support)
  — versions, security types, encodings and pseudo-encodings
- [Benchmarks](benchmarks.md) — CPU, wakeups, first-frame latency,
  high-latency pacing and decode throughput against RoyalVNCKit, and how to
  reproduce them

## Repository

Source and issue tracker:
[github.com/loomhand/swift-rfb](https://github.com/loomhand/swift-rfb).
