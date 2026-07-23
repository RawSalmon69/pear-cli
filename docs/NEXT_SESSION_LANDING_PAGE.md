# Next Session: Pear.app Landing Page

Paste this file's content as the opening prompt of a fresh session (or tell the
agent to read `docs/NEXT_SESSION_LANDING_PAGE.md` and execute it).

---

## Task

Build a **modern landing page for Pear.app** (the macOS menu-bar companion in
`companion/`), with a working **Download** button, and deploy it to
**Cloudflare Pages** at **`pear.phanthawas.dev`** (owner-confirmed domain and
host, 2026-07-23).

## Read first

1. `companion/AGENTS.md` — what the app is, full tool list, invariants. The
   page markets THIS app; don't invent features.
2. Memory `[[owner-quality-bar]]` / `[[robustness-over-features]]` — owner
   notices 1px details; prefers boring-robust over clever-fragile.
3. Load the `frontend-design` skill before writing any HTML/CSS — owner asked
   for "modern"; the page must not look like a template default.

## Hard facts the page needs

- App: **Pear** — private, native macOS menu-bar utility. SwiftUI/AppKit,
  on-device and privacy-first, no telemetry, no accounts. Min **macOS 14**,
  Apple Silicon + Intel (universal? verify: CI builds arm64 — check
  `companion-release.yml` before claiming both archs; if arm64-only, say
  "Apple Silicon").
- Tools to showcase (from `companion/AGENTS.md`, keep current): Screenshot
  (⌃⇧S, preview cards, markup, background removal incl. opt-in HD), OCR Grab
  Text (⌃⇧T), QR scan/generate (⌃⇧Q), Windows snap + radial ring, Dock
  Preview, Color Picker, Shelf, Scratchpad, Clipboard history, KeyClu
  shortcut cheat-sheet, Disk sunburst, System monitor, Menu-bar hider,
  Switches, Clean Mode, RunCat runner, one-click Mac cleanup (bundled pear
  CLI, opt-in system caches).
- Distribution: GitHub Releases on `RawSalmon69/pear-cli`, assets named
  `Pear-X.Y.Z.zip` on `companion-v*` tags. Latest at time of writing:
  companion-v2.8.0. Notarized + stapled; auto-updates via Sparkle
  (`companion/appcast.xml` on main).
- **Download button strategy** (asset name is versioned, so no static latest
  URL): client-side JS fetches
  `https://api.github.com/repos/RawSalmon69/pear-cli/releases/latest`… —
  WRONG, careful: `releases/latest` returns the latest release across the
  whole repo INCLUDING CLI `V*` releases. Instead fetch
  `https://api.github.com/repos/RawSalmon69/pear-cli/releases?per_page=15`,
  pick the first release whose `tag_name` starts with `companion-v`, take its
  `.zip` asset's `browser_download_url`, set the button href + show the
  version number. Hardcode a fallback href to
  `https://github.com/RawSalmon69/pear-cli/releases` for JS-off/rate-limited
  cases. No server, no tokens (60 req/h/IP anonymous limit is plenty).
- License/tone constraints: HD background removal model is CC-BY-NC (BRIA
  RMBG-2) — the page must stay **non-commercial**: free download, no pricing,
  no "buy". Personal indie tone is right (app is named after the owner's
  girlfriend; friends-and-family distribution — page can be public-polished
  but must not oversell it as a supported commercial product).

## Site implementation

- Static only, no framework, no build step (robustness bar): `site/` dir at
  repo root — `index.html` + `style.css` + small inline JS for the download
  resolver. Self-contained; system font stack or one self-hosted font file;
  no CDN dependencies.
- Modern look: dark-first with light support (`prefers-color-scheme`), big
  hero (app name, one-line pitch, Download button + "vX.Y.Z · macOS 14+"
  microcopy), feature grid with the tools above (SF-Symbols-style glyphs can
  be inline SVG), a privacy/on-device section, Sparkle auto-update mention,
  footer linking the GitHub repo + licenses. Keyboard-shortcut chips (⌃⇧S
  etc.) make good visual texture.
- Screenshots problem: this box cannot capture the app (screen-capture is
  permission-gated, and never live-smoke overlay features on the owner's
  machine). Either (a) ask the owner to drop real screenshots into
  `site/assets/` mid-session, or (b) ship v1 with a clean device-frame
  mockup/feature-card design that needs no screenshots, and leave an obvious
  slot for them. Do not fake screenshots.

## Deploy (Cloudflare Pages)

Owner is non-expert on infra — explain each step plainly ([[explain-infra-plainly]]).

1. Preferred: owner creates a Cloudflare API token (Pages:Edit) OR does the
   dashboard flow while the agent guides:
   Dashboard → Workers & Pages → Create → Pages → Connect to git →
   `RawSalmon69/pear-cli` → build command: none, output dir: `site`.
   (If connecting the whole repo feels heavy, alternative: direct upload via
   `npx wrangler pages deploy site --project-name pear-landing` with the API
   token — no repo connect needed; each deploy is one command.)
2. Custom domain: Pages project → Custom domains → add `pear.phanthawas.dev`.
   If `phanthawas.dev` DNS is on Cloudflare this is one click (auto-CNAME);
   otherwise owner adds a CNAME record `pear` → `<project>.pages.dev` at
   their DNS host. HTTPS is automatic.
3. Verify: `curl -sI https://pear.phanthawas.dev` → 200; open the page; click
   Download → browser gets `Pear-X.Y.Z.zip`; check both color schemes and
   mobile width (page must not horizontal-scroll).

## Definition of done

- Page live at https://pear.phanthawas.dev, modern, dark+light, mobile-ok.
- Download button resolves the latest `companion-v*` release zip dynamically,
  shows the version, and has a working no-JS fallback.
- No external runtime dependencies (fonts/CDN/scripts) on the page.
- `site/` committed to main; deploy path documented in `site/README.md`
  (one paragraph: how it deploys, how to update).
- Owner confirmed the look (show it via dev preview URL or local file before
  wiring the domain).
