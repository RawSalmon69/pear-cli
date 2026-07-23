# App Full Clean (system caches from Pear.app) — Design

**Date:** 2026-07-23
**Products:** `pear` CLI (`bin/clean.sh`) + Pear.app companion (Cleaner panel)
**Status:** Approved by owner (2026-07-23), pending spec review

## Problem

The companion's Cleaner panel runs `pear clean` headless (stdin = /dev/null).
`bin/clean.sh` detects no TTY (`[[ -t 0 ]]`) and takes the non-interactive
branch, which only *adopts* an already-cached sudo session and otherwise skips
system-level cleanup. The CLI already has a native osascript password dialog
(`request_sudo_access` GUI mode in `lib/core/sudo.sh`) used by optimize and
batch uninstall from the app — clean just never requests it headless.

## Safety assessment (why this is safe to enable)

`clean_deep_system` (`lib/clean/system.sh`) deletes only age-gated cache/tmp/
log/crash-report files under `/Library/Caches`, `/private/tmp`,
`/private/var/tmp`, `/Library/Logs/DiagnosticReports`, `/private/var/log`,
Adobe log dirs, and `/Library/Updates` — every path through
`should_protect_path` + `safe_sudo_remove`/`safe_sudo_find_delete`, with
`sudo -n` (no mid-run prompts). This is the exact code that runs when a user
presses Enter at the terminal sudo gate; only the entry point changes. No new
deletion logic, no new matchers.

## Design

### CLI: `pe clean --system`

- New flag, parsed in `main()` next to `--dry-run`; sets
  `SYSTEM_CLEAN_REQUESTED=true`.
- Non-interactive branch (`bin/clean.sh` ~line 1134): after `adopt_sudo_session`
  fails, if `SYSTEM_CLEAN_REQUESTED`, call
  `ensure_sudo_session "System cleanup requires admin access"` — headless →
  GUI mode → native macOS password dialog (title "Pear"). Success →
  `SYSTEM_CLEAN=true`; cancel/failure → system section skipped, user-level
  proceeds (existing message).
- Interactive branch: `--system` behaves like pressing Enter at the existing
  gate — straight to `ensure_sudo_session`, no Enter/Space prompt.
- **Without the flag, headless behavior is unchanged** — scripts/CI running
  `pear clean` never get a surprise dialog.
- Existing `PEAR_TEST_MODE`/`PEAR_TEST_NO_AUTH` guards in `request_sudo_access`
  make the flag a no-op skip in tests (auth returns 1 → graceful skip).
- `--help` text gains the flag.

### App: settings toggle

- "Clean includes system caches" toggle in the Settings popover (persistent,
  discoverable before a run — the Cleaner panel only exists once a run is
  live), persisted via `Prefs`, **default OFF** (repo invariant:
  state-mutating behavior is opt-in).
- ON → `CleanerRunner.run` launches `pear clean --system`; the CLI pops the
  native auth dialog when no sudo session is cached. Applies to clean only,
  not optimize (optimize already handles its own auth).
- Update `CleanerRunner` doc comment (it currently documents the skip).

## Testing

- Bats: `--system` parses; non-interactive + `PEAR_TEST_NO_AUTH=1` → system
  section skipped gracefully, user-level proceeds; no-flag headless behavior
  unchanged; unknown-flag error path untouched.
- Swift: `CleanerRunner` argument construction (toggle on → `--system`
  appended; off → not).
- Real dialog smoke = owner's job (auth prompts are never triggered in
  CI/agent verification per repo rules).
