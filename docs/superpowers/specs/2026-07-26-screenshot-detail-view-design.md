# Screenshot detail view — design

Date: 2026-07-26
Product: Pear.app companion (`companion/`)
Status: **SUPERSEDED (2026-07-27) — shipped, then extended past this document.**
Kept for the problem statement and the original scoping decisions. What it now
gets wrong:

- "Out of scope: zoom/pan (fit only)" is false. v2.14.0 shipped full zoom —
  pinch, ⌘-scroll, double-click, ⌘+/⌘−/⌘0 and a zoom capsule over an
  `NSScrollView` with a centering clip view (`ZoomableImageScrollView`).
- The **eyedropper** does not appear here at all: arming from the Colors
  section, a crosshair cursor, `PixelSampler` reading exact image pixels, one
  pick per arming.
- `PaletteColor` was never built — the palette reuses the colour picker's
  existing `PickedColor`, one colour type for the whole app.
- The OCR reuse landed as a separate nonisolated `OCRText` enum
  (`recognize(in:)` / `recognize(inImageData:)`), not as a visibility change on
  `OCRService.recognizeText(in:)`.
- Test counts in this document are stale (432 as of 2026-07-27).

`companion/AGENTS.md` is the current description of the detail window.

## Problem

The post-capture preview card is a 208×130 thumbnail. It carries every action
(copy, save, reveal, background-remove, markup, send, copy-text, QR badge) but
no room to *look* at the shot or at what is in it. The owner wants a click on
the card to open a bigger view with the same actions, plus what Pear already
knows about the image shown alongside: QR payloads, recognized text, and file
facts — scanned ahead of time so the panel is populated the moment it opens.

## Shape

Single click on a card's thumbnail opens one detail window for that card. The
card stays on screen. Clicking the same card again focuses the existing window
rather than opening a second one.

```
┌────────────────────────────┬──────────────┐
│                            │ TEXT       ⧉ │
│                            │ ┌──────────┐ │
│        image (fit)         │ │ Lorem ip… │ │
│                            │ └──────────┘ │
│                            │ QR         ⧉ │
│                            │ https://ex…  │
│                            │ COLORS       │
│                            │ ■ ■ ■ ■ ■ ■  │
│                            │ DETAILS      │
│                            │ 2560 × 1600  │
│                            │ PNG · 1.2 MB │
├────────────────────────────┴──────────────┤
│ ⧉ Copy  ⤓ Save  ▤ Reveal  ⌦ BG  ✎ Markup │
└───────────────────────────────────────────┘
```

## Components

### `Services/ScreenshotInsights.swift` (new)

`@MainActor @Observable final class ScreenshotInsights` — one per card, the
single owner of everything-but-the-pixels. Replaces `PreviewQRState`, which
only held QR payloads.

- `details: ScreenshotDetails` — computed synchronously at init from the PNG
  header (no full decode): pixel size, byte count, format, capture time,
  optional saved path.
- `text: String`, `payloads: [String]`, `colors: [PaletteColor]` — filled by
  `scan()`.
- `scan()` — idempotent; runs OCR + barcode detect + palette in ONE detached
  `.utility` task and assigns the results back on the main actor. Called by
  `ScreenshotPreviewController.show` **after** the panel is on screen, so the
  capture → preview hop is never delayed. Per-section `scanning` flag drives a
  spinner if the window opens mid-scan.

Supporting value types in the same file, all pure and unit-tested:

- `struct ScreenshotDetails: Sendable` + `dimensionsLabel` / `sizeLabel` /
  `timeLabel`, and `format(sniffing:)` reading magic bytes (PNG, JPEG, else
  "Image"). `from(imageData:fileURL:now:)` takes `now` so tests are stable.
- `struct PaletteColor: Sendable, Hashable` — RGB doubles plus `hex` and a
  SwiftUI `Color`; Sendable so it crosses the detached-task boundary.
- `enum DominantColors { static func palette(from:count:) -> [PaletteColor] }` —
  ImageIO thumbnail down to 64px, drawn into an Nx1 RGBA context, pixels read
  back. No Vision, no dependency, ~25 lines.

`OCRService.recognizeText(in:)` becomes non-private (`text(in:)`) so insights
reuse the existing Vision path instead of a second copy. `QRCode.decode(in:)`
is reused as-is.

### `Views/ScreenshotDetailWindow.swift` (new)

- `enum ScreenshotDetailLayout` — `windowSize(image:visible:sidebar:minimum:)`,
  pure: fit the image aspect inside 70% of the visible frame, add the sidebar
  width, clamp to a 720×480 floor. Unit-tested for tall, wide, and tiny images.
- `ScreenshotDetailWindowController` — a titled/closable/resizable `NSWindow`
  hosting SwiftUI (a real window, not the small floating panel the pure-AppKit
  gotcha covers), centered on the primary display, `cancelOperation` override
  closes on Esc (the pattern already used by Disk/Monitor/Scratchpad windows).
- `ScreenshotDetailView` — image fit on the left, 260pt sidebar right with
  Text / QR / Colors / Details sections (each with a copy affordance; palette
  swatches copy their hex), action bar along the bottom mirroring the card:
  Copy (⌘C), Save (⌘S, only when auto-save is off), Reveal, Remove background,
  Markup, Send. Empty sections are omitted rather than shown blank.

### Wiring

`ScreenshotPreviewController.show` gains `fileURL: URL?` (for the details
section) and builds the `ScreenshotInsights` itself, so both callers
(`ScreenshotService`, `QRService.presentGenerated`) get insights and detail
windows for free with no per-caller policy. Each `PreviewEntry` keeps the
image data, its insights, and the action closures, so `openDetail(id:)` needs
no extra plumbing. The card's thumbnail gets `.onTapGesture`; drag still wins
once the pointer moves, so swipe-to-dismiss is unaffected. Toolbar buttons
consume their own clicks, so they never open the window.

`onQRTap` changes from `() -> Void` to `([String]) -> Void` because insights,
not the service, now own the payloads.

## Mutating actions

Markup and Remove-background in the detail window close it and run the card's
existing closures, which re-present a fresh card (and fresh insights) for the
new image. No second image-state machine to keep in sync — same behavior those
buttons already have on the card.

## Out of scope

Zoom/pan (fit only), text selection over the image itself, persisting insights
across relaunch, and any new preference. Say so explicitly if one is wanted.

## Verification

`swift build`, `swift test` (395 green today) with new cases for the layout
clamp, palette extraction on a synthetic two-color image, format sniffing, and
detail label formatting. The window and card interaction are visual — owner
smoke, as with every overlay in this app.
