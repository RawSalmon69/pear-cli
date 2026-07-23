# App Full Clean Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Pear.app run a full `pear clean` including system caches, via a new `pe clean --system` flag that uses the CLI's existing native password dialog when headless, behind a default-OFF app setting.

**Architecture:** One new CLI flag (`SYSTEM_CLEAN_REQUESTED`) consulted at the existing sudo gate in `start_cleanup`; headless + flag → `ensure_sudo_session` (whose GUI mode already pops the native osascript dialog). App side: a `Prefs` toggle + a pure argument-builder in `CleanerRunner`. No new deletion logic anywhere.

**Tech Stack:** bash 3.2-compatible shell, bats tests; Swift 6 for the companion toggle.

**Spec:** `docs/superpowers/specs/2026-07-23-app-full-clean-design.md`

## Global Constraints

- bash 3.2 pitfalls apply (see root `AGENTS.md` Shell and Test Pitfalls) — no empty-array expansion without a length guard, no `[[ -n ]] && cmd` inside exit-code-sensitive blocks.
- `PEAR_TEST_MODE`/`PEAR_TEST_NO_AUTH` must keep all auth paths inert in tests; never trigger a real sudo/osascript prompt in verification.
- Without `--system`, headless `pear clean` behavior must be byte-identical (scripts/CI must never get a surprise dialog).
- Shell formatting: `./scripts/check.sh --format` must pass.
- This touches `bin/clean.sh` (destructive-sink orchestrator): run the `safety-reviewer` agent on the diff before merge.
- Companion: min macOS 14, `swift test` green, update `companion/AGENTS.md` in the same change.

---

### Task 1: CLI — `pe clean --system` flag + auth at the gate

**Files:**
- Modify: `bin/clean.sh` (init ~line 25, `start_cleanup` gate lines 1126–1146, `main()` case list line 1531)
- Modify: `lib/core/help.sh` (`show_clean_help`)
- Test: `tests/clean_core.bats`

**Interfaces:**
- Consumes: `adopt_sudo_session` / `ensure_sudo_session` from `lib/core/sudo.sh` (both return 1 under `PEAR_TEST_MODE`/`PEAR_TEST_NO_AUTH`).
- Produces: global `SYSTEM_CLEAN_REQUESTED` (`true`/`false` string, default `false`); `--system` flag; used verbatim by Task 2's app arguments.

- [ ] **Step 1: Write the failing tests**

Append to `tests/clean_core.bats` (follow the sourcing pattern of `pe clean adopts cached sudo before system cleanup (#1084)` at line 119):

```bash
@test "pe clean --system parses and dry-run stays adopt-only" {
    run env HOME="$HOME" PEAR_TEST_MODE=1 "$PROJECT_ROOT/pear" clean --system --dry-run
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"Unknown option"* ]] || return 1
    # Dry-run preview must not attempt auth even with the flag.
    [[ "$output" == *"sudo -v && pe clean --dry-run"* ]] || return 1
}

@test "pe clean --system headless skips gracefully when auth unavailable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PEAR_TEST_NO_AUTH=1 PEAR_TEST_MODE=1 \
        bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
EXTERNAL_VOLUME_TARGET=""
SYSTEM_CLEAN_REQUESTED=true
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=$SYSTEM_CLEAN"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Running in non-interactive mode"* ]] || return 1
    [[ "$output" == *"System-level cleanup skipped"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]] || return 1
}

@test "pe clean --system headless enables system clean when auth succeeds" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PEAR_TEST_MODE=0 PEAR_TEST_NO_AUTH=0 \
        bash --noprofile --norc <<'SCRIPT'
# set -u only: a sudo function mock returning nonzero inside an if-condition
# trips errexit on the macos-14 runner's bash (see root AGENTS.md pitfalls).
set -u
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
EXTERNAL_VOLUME_TARGET=""
SYSTEM_CLEAN_REQUESTED=true

# adopt must fail (no cached session), the explicit request must succeed:
sudo() { return 1; }
request_sudo_access() { return 0; }
_start_sudo_keepalive() { echo "keepalive-pid"; }
_stop_sudo_keepalive() { :; }

start_cleanup < /dev/null
echo "SYSTEM_CLEAN=$SYSTEM_CLEAN"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"admin access granted"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=true"* ]] || return 1
}

@test "pe clean headless without --system never attempts auth (unchanged)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PEAR_TEST_MODE=0 PEAR_TEST_NO_AUTH=0 \
        bash --noprofile --norc <<'SCRIPT'
# set -u only: see errexit pitfall note in the auth-succeeds test above.
set -u
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
EXTERNAL_VOLUME_TARGET=""

sudo() { return 1; }
request_sudo_access() { echo "AUTH-ATTEMPTED"; return 0; }
_start_sudo_keepalive() { echo "keepalive-pid"; }
_stop_sudo_keepalive() { :; }

start_cleanup < /dev/null
echo "SYSTEM_CLEAN=$SYSTEM_CLEAN"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"AUTH-ATTEMPTED"* ]] || return 1
    [[ "$output" == *"System-level cleanup skipped"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]] || return 1
}
```

Note the repo pitfalls honored here: every assertion ends `|| return 1` (vacuous-pass shape #886), heredoc scripts feed `start_cleanup < /dev/null` (no `read -n1` byte theft), and mocks are shell functions only where nothing `exec`s past them.

- [ ] **Step 2: Run tests to verify they fail**

Run: `PEAR_TEST_NO_AUTH=1 bats tests/clean_core.bats`
Expected: new tests 1 and 3 FAIL (`--system` → "Unknown option"; auth-success
path still yields `SYSTEM_CLEAN=false`). New tests 2 and 4 pin CURRENT behavior
and already pass — they are the regression guards that must stay green after
implementation. All pre-existing tests PASS.

- [ ] **Step 3: Implement the flag**

3a. `bin/clean.sh` near line 25, next to `SYSTEM_CLEAN=false`:

```bash
SYSTEM_CLEAN_REQUESTED=false
```

3b. `main()` case list (after the `"--whitelist"` case):

```bash
            "--system")
                SYSTEM_CLEAN_REQUESTED=true
                ;;
```

3c. `start_cleanup` gate — replace lines 1126–1146 with:

```bash
    if [[ -t 0 ]]; then
        if adopt_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access already available"
            echo ""
        elif [[ "$SYSTEM_CLEAN_REQUESTED" == "true" ]]; then
            # --system: behave as if the user pressed Enter at the gate.
            if ensure_sudo_session "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
            else
                SYSTEM_CLEAN=false
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
                echo ""
            fi
        else
            prompt_for_system_clean
        fi
    else
        echo ""
        echo "Running in non-interactive mode"
        if adopt_sudo_session; then
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, sudo session active"
        elif [[ "$SYSTEM_CLEAN_REQUESTED" == "true" ]] && ensure_sudo_session "System cleanup requires admin access"; then
            # Headless --system: ensure_sudo_session's GUI mode pops the native
            # macOS password dialog (lib/core/sudo.sh request_sudo_access).
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, admin access granted"
        else
            SYSTEM_CLEAN=false
            echo "  ${ICON_LIST} System-level cleanup skipped, requires sudo"
        fi
        echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
        echo ""
    fi
```

(The dry-run preview branch earlier in `start_cleanup` — lines 1113–1123 —
stays adopt-only on purpose: a preview must never prompt.)

3d. `lib/core/help.sh` `show_clean_help`: add, matching the existing option-line format exactly:

```
--system     Include system caches (asks for admin access, native dialog when headless)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `PEAR_TEST_NO_AUTH=1 bats tests/clean_core.bats`
Expected: ALL pass, including the 4 new tests.

- [ ] **Step 5: Format + syntax checks**

```bash
./scripts/check.sh --format
find bin lib -name '*.sh' -print0 | xargs -0 -n1 bash -n
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add bin/clean.sh lib/core/help.sh tests/clean_core.bats
git commit -m "feat(clean): --system flag — explicit system-cache cleanup with native auth when headless"
```

---

### Task 2: App — settings toggle + `--system` argument

**Files:**
- Modify: `companion/Sources/PearCompanion/Support/Prefs.swift`
- Modify: `companion/Sources/PearCompanion/Services/CleanerRunner.swift`
- Modify: `companion/Sources/PearCompanion/Views/SettingsPopover.swift`
- Test: `companion/Tests/PearCompanionTests/CleanerRunnerTests.swift`

**Interfaces:**
- Consumes: `pe clean --system` (Task 1).
- Produces: `Prefs.cleanIncludeSystemCaches: Bool` (default false), `CleanerRunner.arguments(for:includeSystemCaches:) -> [String]`.

- [ ] **Step 1: Write the failing test**

Append to `CleanerRunnerTests.swift` (match its existing style):

```swift
    func testArgumentsIncludeSystemFlagOnlyForCleanWhenEnabled() {
        XCTAssertEqual(CleanerRunner.arguments(for: "clean", includeSystemCaches: true),
                       ["clean", "--system"])
        XCTAssertEqual(CleanerRunner.arguments(for: "clean", includeSystemCaches: false),
                       ["clean"])
        // optimize handles its own auth; the flag is clean-only.
        XCTAssertEqual(CleanerRunner.arguments(for: "optimize", includeSystemCaches: true),
                       ["optimize"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd companion && swift test --filter CleanerRunnerTests`
Expected: compile FAILURE — `arguments(for:includeSystemCaches:)` not defined.

- [ ] **Step 3: Implement**

3a. `Prefs.swift` — key constant next to the others, property after `hdBackgroundRemoval`:

```swift
    static let cleanSystemCachesKey = "cleanIncludeSystemCaches"
```

```swift
    /// Opt-in: the app's Clean button also cleans system caches, which asks
    /// for an admin password via the CLI's native dialog. Default off.
    static var cleanIncludeSystemCaches: Bool {
        UserDefaults.standard.bool(forKey: cleanSystemCachesKey)
    }
```

3b. `CleanerRunner.swift` — pure builder + use it in `run` (replace `process.arguments = [command]`):

```swift
    /// clean gets --system when the user opted in; optimize already pops its
    /// own native auth dialog for admin tasks and takes no flag.
    nonisolated static func arguments(for command: String, includeSystemCaches: Bool) -> [String] {
        guard command == "clean", includeSystemCaches else { return [command] }
        return [command, "--system"]
    }
```

```swift
        process.arguments = Self.arguments(
            for: command, includeSystemCaches: Prefs.cleanIncludeSystemCaches)
```

Also update the class doc comment (lines 4–8): the "or is skipped (clean's
system caches)" clause becomes "…or is skipped (clean's system caches — unless
the Include-system-caches setting passes `--system`, which pops the CLI's
native auth dialog)".

3c. `SettingsPopover.swift` — add a toggle row, matching the exact style of the
neighboring rows (e.g. the `Toggle("Sound effects", ...)` at line 214 — same
state-binding pattern the file already uses, `@AppStorage` or `@State`+`onChange`,
whichever its rows use):

```swift
            Toggle("Clean includes system caches", isOn: $cleanSystemCaches)
                .font(Theme.body)
                .toggleStyle(.switch)
```

with binding storage:

```swift
    @AppStorage(Prefs.cleanSystemCachesKey) private var cleanSystemCaches = false
```

and a caption below it in the file's caption style:

```swift
            Text("Asks for your admin password when Clean runs.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
```

Place it in the section where general app behavior toggles live (same group as
"Sound effects" / "Open at login").

- [ ] **Step 4: Run tests**

Run: `cd companion && swift test`
Expected: all pass, including the new CleanerRunner test.

- [ ] **Step 5: Update companion/AGENTS.md**

In Services bullet, extend the Cleaner mention: "Cleaner (headless `pear
clean/optimize` into a panel; opt-in Include-system-caches setting passes
`clean --system` → native auth dialog)".

- [ ] **Step 6: Commit**

```bash
git add companion/Sources/PearCompanion/Support/Prefs.swift companion/Sources/PearCompanion/Services/CleanerRunner.swift companion/Sources/PearCompanion/Views/SettingsPopover.swift companion/Tests/PearCompanionTests/CleanerRunnerTests.swift companion/AGENTS.md
git commit -m "feat(companion): opt-in full clean — settings toggle passes clean --system"
```

---

### Task 3: Full verification + safety review

- [ ] **Step 1: Full CLI suite**

Run: `PEAR_TEST_NO_AUTH=1 ./scripts/test.sh`
Expected: all bats pass.

- [ ] **Step 2: Full companion suite + build**

Run: `cd companion && swift build && swift test`
Expected: green.

- [ ] **Step 3: Safety review**

Dispatch the `safety-reviewer` agent on the `bin/clean.sh` + `lib/core/help.sh`
diff (repo rule for destructive-sink files). Address any findings before merge.

**Owner smoke checklist (post-merge):** toggle ON → panel Clean → native
password dialog appears → transcript shows "System-level cleanup enabled";
dialog Cancel → clean continues user-level only; toggle OFF → no dialog ever.
