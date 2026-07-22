# QR Tools — Design

**Date:** 2026-07-23
**Product:** Pear.app companion (`companion/`)
**Status:** Approved by owner (brainstorm 2026-07-23)

## Goal

Scan QR codes from anywhere on screen with the familiar crosshair flow, generate
QR codes from the clipboard, and surface both on the post-screenshot preview
cards — plus a one-tap "copy text" (OCR) action on those cards.

Out of scope (decided during brainstorm):

- **Translation** — dropped by owner mid-brainstorm.
- **Redact/blur/pixelate** — already shipped: markup's `blur` tool
  (`MarkupModel.swift`) renders pixelation via `Pixelation.pixelated`.
- **"Scan QR" button on preview cards** — redundant with the auto badge
  (same image, same decoder); merged into the badge.
- Parsing structured payloads (WiFi `WIFI:…`, vCard) — copy raw string; YAGNI.

## Components

### 1. `QRService` (`Sources/PearCompanion/Services/QRService.swift`)

Mirrors `OCRService` exactly in shape (`@MainActor` final class, Logger,
UNUserNotificationCenter notify helper).

- `scanFromScreen() async` — `ScreenCapture.region(to:)` crosshair → temp PNG →
  `decode(cgImage)` → result handling. Cancelled capture = no-op (same as OCR).
- `decode(_ cgImage: CGImage) -> [String]` — `VNDetectBarcodesRequest`, default
  symbologies (QR **and** linear barcodes decode at zero extra cost). Returns
  payload strings.
- Result handling:
  - ≥1 payload → clipboard (newline-joined if multiple) + `SoundEffects.play(.done)`
    + notification. Multiple codes: count in the notification title.
  - Payload is a URL (single payload, `URL(string:)` with http/https scheme) →
    notification carries an **Open** action button via `UNNotificationCategory`;
    activating it opens the URL in the default browser. Requires setting the
    app as `UNUserNotificationCenter` delegate to receive the action response.
  - 0 payloads → "No QR code found" notification (mirror of OCR's no-text path).
- `generateFromClipboard()` — clipboard string → `CIFilter` QR generator
  (`CIQRCodeGenerator`, correction level M) → nearest-neighbor upscale to a
  crisp PNG → shown as a card in the existing screenshot preview stack
  (write temp PNG, call `ScreenshotPreviewController.show`). The card's
  existing copy/reveal/dismiss actions apply; markup/send/background-removal
  are disabled for generated cards. Empty or non-text clipboard →
  "Nothing to encode" notification.

### 2. QR Tool (`Sources/PearCompanion/Tools/QR/QRTool.swift`)

- `id: "qr"`, title "QR", icon `qrcode.viewfinder`, capture category.
- Default hotkey **⌃⇧Q** → `scanFromScreen()` directly.
- Panel entry: popover with two buttons — **Scan screen** and **QR from
  clipboard**.
- Registered like other per-directory tools; disabled = never registered
  (standard `ToolRegistry` behavior).

### 3. Preview card: Copy text action

- New `PreviewAction` (symbol `text.viewfinder`, help "Copy text") on
  screenshot preview cards.
- Runs the existing Vision OCR path on that card's image. `OCRService` gains a
  public `copyText(from cgImage: CGImage)` extracted from `grab()` (recognize →
  clipboard → sound → notification); `grab()` becomes capture + that method.
- Not shown on QR-generated cards.

### 4. Preview card: auto QR badge

- When a screenshot preview entry is created, a background task decodes the
  full-resolution capture (`QRService.decode`, ~tens of ms).
- Found → small `qrcode` badge overlays the card; clicking it runs the same
  result flow as a scan (clipboard + notification + Open-if-URL).
- Not found → nothing appears. No badge on generated-QR cards.
- Mechanics: each card view observes a tiny per-entry `@Observable` state box
  (`qrPayloads: [String]?`) that the detection task fills in; view shows the
  badge when non-empty. Detection must never delay the card's slide-in.

## Error handling

- Vision request throws → log via `Logger`, treat as 0 payloads.
- Temp file cleanup via `defer` (same pattern as OCR).
- Notification permission denied → actions still copy to clipboard; sound still
  plays (existing app-wide behavior).

## Testing (`swift test`, no screen/permission dependencies)

- **Roundtrip:** generate QR image from string via the generator, decode with
  `decode(_:)`, expect the original string. Covers both directions with zero
  fixtures.
- **URL detection:** http/https payload → URL branch; plain text / mailto →
  plain branch.
- **Multi-code join:** two payloads → newline-joined clipboard string, count
  in title.
- **Empty clipboard →** "Nothing to encode" path.
- **Badge state box:** payloads set → badge visible flag; nil/empty → hidden.
- UI smoke (hotkey, popover, badge click) = owner's job per repo rule (this
  box's capture/AX is permission-gated).

## Constraints honored

- Native primitives only: Vision `VNDetectBarcodesRequest` (macOS 14-safe),
  `CIQRCodeGenerator`, existing `screencapture -i` seam. No new dependencies.
- No new floating window surface — generator reuses the preview stack.
- New tool defaults ON is fine (mutates nothing, covers nothing on launch);
  hotkey rebindable like every tool.
