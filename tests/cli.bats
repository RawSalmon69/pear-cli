#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	# Capture real GOCACHE before HOME is replaced with a temp dir.
	# Without this, go build would use $HOME/Library/Caches/go-build inside the
	# temp dir (empty), causing a full cold rebuild on every test run (~6s).
	ORIGINAL_GOCACHE="$(go env GOCACHE 2>/dev/null || true)"
	export ORIGINAL_GOCACHE

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-cli-home.XXXXXX")"
	export HOME

	mkdir -p "$HOME"

	CLI_OWNS_GO_HELPERS=0
	export CLI_OWNS_GO_HELPERS

	if [[ -x "${PEAR_TEST_ANALYZE_BIN:-}" && -x "${PEAR_TEST_STATUS_BIN:-}" ]]; then
		ANALYZE_BIN="$PEAR_TEST_ANALYZE_BIN"
		STATUS_BIN="$PEAR_TEST_STATUS_BIN"
		export ANALYZE_BIN STATUS_BIN
	elif command -v go > /dev/null 2>&1; then
		# Build Go binaries from current source for JSON tests.
		# Point GOPATH/GOMODCACHE/GOCACHE at the real home so local focused runs
		# can reuse caches when the full runner did not prebuild helpers.
		ANALYZE_BIN="$(mktemp "${TMPDIR:-/tmp}/analyze-go.XXXXXX")"
		STATUS_BIN="$(mktemp "${TMPDIR:-/tmp}/status-go.XXXXXX")"
		GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
			GOCACHE="${ORIGINAL_GOCACHE}" \
			go build -o "$ANALYZE_BIN" "$PROJECT_ROOT/cmd/analyze" 2>/dev/null
		GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
			GOCACHE="${ORIGINAL_GOCACHE}" \
			go build -o "$STATUS_BIN" "$PROJECT_ROOT/cmd/status" 2>/dev/null
		CLI_OWNS_GO_HELPERS=1
		export ANALYZE_BIN STATUS_BIN
	fi
}

teardown_file() {
	if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		rm -rf "$HOME/.config/pear"
		rm -rf "$HOME"
	fi
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
	if [[ "${CLI_OWNS_GO_HELPERS:-0}" == "1" ]]; then
		rm -f "${ANALYZE_BIN:-}" "${STATUS_BIN:-}"
	fi
}

create_fake_utils() {
	local dir="$1"
	mkdir -p "$dir"

	cat >"$dir/sudo" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-n" || "$1" == "-v" ]]; then
    exit 0
fi
exec "$@"
SCRIPT
	chmod +x "$dir/sudo"

	cat >"$dir/bioutil" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then
    echo "Touch ID: 1"
    exit 0
fi
exit 0
SCRIPT
	chmod +x "$dir/bioutil"

	cat >"$dir/chown" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
	chmod +x "$dir/chown"

	cat >"$dir/install" <<'SCRIPT'
#!/usr/bin/env bash
args=()
skip_next=""
for arg in "$@"; do
    if [[ -n "$skip_next" ]]; then skip_next=""; continue; fi
    case "$arg" in -o|-g) skip_next=1 ;; *) args+=("$arg") ;; esac
done
exec /usr/bin/install "${args[@]}"
SCRIPT
	chmod +x "$dir/install"
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	rm -rf "$HOME/.config/pear"
	mkdir -p "$HOME/.config/pear"
}

@test "pear --help prints command overview" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"pear clean"* ]]
	[[ "$output" == *"pear optimize"* ]]
	[[ "$output" == *"pear analyze"* ]]
	[[ "$output" != *"pear optimise"* ]]
}

@test "pear --version reports script version" {
	expected_version="$(grep '^VERSION=' "$PROJECT_ROOT/pear" | head -1 | sed 's/VERSION=\"\(.*\)\"/\1/')"
	run env HOME="$HOME" "$PROJECT_ROOT/pear" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"$expected_version"* ]]
}

@test "pear --version does not hang on slow Homebrew detection" {
	local fake_bin
	fake_bin="$(mktemp -d "${BATS_TEST_TMPDIR}/fake-bin.XXXXXX")"
	ln -s "$PROJECT_ROOT/pear" "$fake_bin/pear"
	cat > "$fake_bin/brew" <<'SCRIPT'
#!/usr/bin/env bash
sleep 3
exit 1
SCRIPT
	chmod +x "$fake_bin/brew"

	run env HOME="$HOME" PATH="$fake_bin:$PATH" PEAR_HOMEBREW_DETECT_TIMEOUT=1 "$PROJECT_ROOT/pear" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Install: Manual"* ]]
}

@test "pear --version shows nightly channel metadata" {
	expected_version="$(grep '^VERSION=' "$PROJECT_ROOT/pear" | head -1 | sed 's/VERSION=\"\(.*\)\"/\1/')"
	mkdir -p "$HOME/.config/pear"
	cat > "$HOME/.config/pear/install_channel" <<'EOF'
CHANNEL=nightly
EOF

	run env HOME="$HOME" "$PROJECT_ROOT/pear" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Pear version $expected_version"* ]]
	[[ "$output" == *"Channel: Nightly"* ]]
}

@test "pear unknown command returns error" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" unknown-command
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: unknown-command"* ]]
}

@test "pear --help does not list check command" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" --help
	[ "$status" -eq 0 ]
	[[ "$output" != *"pear check"* ]]
}

@test "pear --help documents history command" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"pear history"* ]]
}

@test "pear check is not a public command" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" check --help
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: check"* ]]
}

@test "pear doctor is not a public command" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" doctor --help
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: doctor"* ]]
}

@test "pear optimize --check is not a public option" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" optimize --check
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown optimize option: --check"* ]]
}

@test "pear uninstall --whitelist returns unsupported option error" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" uninstall --whitelist
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown uninstall option: --whitelist"* ]]
}

@test "main menu controls line shows the update shortcut only when an update is available" {
	# The controls line is rendered only under a tty, so test the pure builder
	# directly. Both the negative and positive cases run so the assertion
	# cannot pass vacuously.
	run bash --noprofile --norc -c "PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1 HOME=\"\$(mktemp -d)\" source '$PROJECT_ROOT/pear'; _main_menu_controls_line true false"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"U Update"* ]] || return 1

	run bash --noprofile --norc -c "PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1 HOME=\"\$(mktemp -d)\" source '$PROJECT_ROOT/pear'; _main_menu_controls_line true true"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"U Update"* ]] || return 1

	# TouchID setup takes precedence: no update shortcut even if one is ready.
	run bash --noprofile --norc -c "PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1 HOME=\"\$(mktemp -d)\" source '$PROJECT_ROOT/pear'; _main_menu_controls_line false true"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"T TouchID"* ]] || return 1
	[[ "$output" != *"U Update"* ]] || return 1
}

@test "show_main_menu keeps history out of the primary menu" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1
source "$PROJECT_ROOT/pear"
show_brand_banner() { printf 'banner\n'; }
show_menu_option() { printf '%s\n' "$2"; }
MAIN_MENU_BANNER=""
MAIN_MENU_UPDATE_MESSAGE=""
MAIN_MENU_SHOW_UPDATE=false
show_main_menu 1 true
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Clean        Free up disk space"* ]]
	[[ "$output" != *"History"* ]]
	[[ "$output" != *"history"* ]]
}

@test "interactive_main_menu ignores U shortcut when update notice is hidden" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1
source "$PROJECT_ROOT/pear"
show_brand_banner() { :; }
show_main_menu() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
update_pear() { echo "UPDATE_CALLED"; }
state_file="$HOME/read_key_state"
read_key() {
    if [[ ! -f "$state_file" ]]; then
        : > "$state_file"
        echo "UPDATE"
    else
        echo "QUIT"
    fi
}
interactive_main_menu
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"UPDATE_CALLED"* ]]
}

@test "read_update_message_cache ignores notices older than current script" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1
mkdir -p "$HOME/.cache/pear"
msg_cache="$HOME/.cache/pear/update_message"
printf 'Update 1.43.0 available, run pe update\n' > "$msg_cache"
touch -t 200001010000 "$msg_cache"
source "$PROJECT_ROOT/pear"
message="$(read_update_message_cache "$msg_cache")"
[[ -z "$message" ]]
[[ ! -s "$msg_cache" ]]
EOF

	[ "$status" -eq 0 ]
}

@test "interactive_main_menu accepts U shortcut when update notice is visible" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1
mkdir -p "$HOME/.cache/pear"
printf 'update available\n' > "$HOME/.cache/pear/update_message"
source "$PROJECT_ROOT/pear"
show_brand_banner() { :; }
show_main_menu() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
update_pear() { echo "UPDATE_CALLED"; }
read_key() { echo "UPDATE"; }
interactive_main_menu
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"UPDATE_CALLED"* ]]
}

@test "interactive_main_menu drains numeric shortcut Enter before launching uninstall" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME PEAR_TEST_MODE=1 PEAR_SKIP_MAIN=1
source "$PROJECT_ROOT/pear"

fake_root="$HOME/fake-pear"
mkdir -p "$fake_root/bin"
cat > "$fake_root/bin/uninstall.sh" <<'SCRIPT'
#!/usr/bin/env bash
if IFS= read -r -s -n1 -t 0.1 key; then
    if [[ -z "$key" ]]; then
        echo "LEAK:ENTER"
    else
        printf 'LEAK:%s\n' "$key"
    fi
else
    echo "NO_LEAK"
fi
SCRIPT
chmod +x "$fake_root/bin/uninstall.sh"

SCRIPT_DIR="$fake_root"
show_brand_banner() { :; }
show_main_menu() { :; }
hide_cursor() { :; }
show_cursor() { :; }

interactive_main_menu < <(printf '2\n')
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"NO_LEAK"* ]]
	[[ "$output" != *"LEAK:"* ]]
}

@test "touchid status reports current configuration" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" touchid status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Touch ID"* ]]
}

@test "pe optimize command is recognized" {
	run bash -c "grep -Eq '\"optimi[sz]e\"[[:space:]]*\\|[[:space:]]*\"optimi[sz]e\"' '$PROJECT_ROOT/pear'"
	[ "$status" -eq 0 ]
}

@test "pe analyze binary is valid" {
	if [[ -f "$PROJECT_ROOT/bin/analyze-go" ]]; then
		[ -x "$PROJECT_ROOT/bin/analyze-go" ]
		run file "$PROJECT_ROOT/bin/analyze-go"
		[[ "$output" == *"Mach-O"* ]] || [[ "$output" == *"executable"* ]]
	else
		skip "analyze-go binary not built"
	fi
}

@test "pe clean --debug creates debug log file" {
	mkdir -p "$HOME/.config/pear"
	run env HOME="$HOME" TERM="xterm-256color" PEAR_TEST_MODE=1 PE_DEBUG=1 "$PROJECT_ROOT/pear" clean --dry-run
	[ "$status" -eq 0 ]
	PEAR_OUTPUT="$output"

	DEBUG_LOG="$HOME/Library/Logs/pear/pear_debug_session.log"
	[ -f "$DEBUG_LOG" ]

	run grep "Pear Debug Session" "$DEBUG_LOG"
	[ "$status" -eq 0 ]

	[[ "$PEAR_OUTPUT" =~ "Debug session log saved to" ]]
}

@test "pe clean without debug does not show debug log path" {
	mkdir -p "$HOME/.config/pear"
	run env HOME="$HOME" TERM="xterm-256color" PEAR_TEST_MODE=1 PE_DEBUG=0 "$PROJECT_ROOT/pear" clean --dry-run
	[ "$status" -eq 0 ]

	[[ "$output" != *"Debug session log saved to"* ]]
}

@test "pe clean --debug logs system info" {
	mkdir -p "$HOME/.config/pear"
	run env HOME="$HOME" TERM="xterm-256color" PEAR_TEST_MODE=1 PE_DEBUG=1 "$PROJECT_ROOT/pear" clean --dry-run
	[ "$status" -eq 0 ]

	DEBUG_LOG="$HOME/Library/Logs/pear/pear_debug_session.log"

	run grep "User:" "$DEBUG_LOG"
	[ "$status" -eq 0 ]

	run grep "Architecture:" "$DEBUG_LOG"
	[ "$status" -eq 0 ]
}

@test "pe clean --help includes external volume option" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" clean --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--external PATH"* ]]
	[[ "$output" == *"already-uninstalled apps"* ]]
}

@test "pe uninstall --help directs leftover-only cleanup to clean" {
	run env HOME="$HOME" "$PROJECT_ROOT/pear" uninstall --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"already gone, use pe clean"* ]]
}

@test "pe clean --external accepts canonicalized custom root" {
	real_root="$(mktemp -d "$HOME/ext-real.XXXXXX")"
	link_root="$HOME/ext-link"
	ln -s "$real_root" "$link_root"
	mkdir -p "$link_root/USB/.Trashes"
	touch "$link_root/USB/.Trashes/cache.tmp"

	mock_bin="$HOME/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/diskutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$mock_bin/diskutil"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PEAR_EXTERNAL_VOLUMES_ROOT="$link_root" \
		PEAR_TEST_NO_AUTH=1 "$PROJECT_ROOT/pear" clean --external "$link_root/USB" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"Clean External Volume"* ]]
	[[ "$output" == *"External volume cleanup"* ]]
}

@test "touchid status reflects pam file contents" {
	pam_file="$HOME/pam_test"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	run env PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"not configured"* ]]

	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
EOF

	run env PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"enabled"* ]]
}

@test "enable_touchid inserts pam_tid line in pam file" {
	pam_file="$HOME/pam_enable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -eq 0 ]
	grep -q "pam_tid.so" "$pam_file"
	[[ -f "${pam_file}.pear-backup" ]]
}

@test "disable_touchid removes pam_tid line" {
	pam_file="$HOME/pam_disable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin-disable"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" disable
	[ "$status" -eq 0 ]
	run grep "pam_tid.so" "$pam_file"
	[ "$status" -ne 0 ]
}

@test "touchid enable --dry-run does not modify pam file" {
	pam_file="$HOME/pam_enable_dry_run"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	run env PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY RUN MODE"* ]]

	run grep "pam_tid.so" "$pam_file"
	[ "$status" -ne 0 ]
}

@test "enable_touchid sets correct file permissions on pam file" {
	pam_file="$HOME/pam_perms_enable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin-perms-enable"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -eq 0 ]
	grep -q "pam_tid.so" "$pam_file"

	local perms
	perms=$(stat -f "%Lp" "$pam_file" 2>/dev/null || stat -c "%a" "$pam_file" 2>/dev/null)
	[ "$perms" = "444" ]
}

@test "disable_touchid sets correct file permissions on pam file" {
	pam_file="$HOME/pam_perms_disable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin-perms-disable"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" PEAR_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" disable
	[ "$status" -eq 0 ]

	local perms
	perms=$(stat -f "%Lp" "$pam_file" 2>/dev/null || stat -c "%a" "$pam_file" 2>/dev/null)
	[ "$perms" = "444" ]
}

@test "enable_touchid sets correct permissions on sudo_local file" {
	pam_file="$HOME/pam_perms_sudolocal"
	pam_local="$(dirname "$pam_file")/sudo_local_perms"
	cat >"$pam_file" <<'EOF'
# sudo: auth account password session
auth       include        sudo_local
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin-perms-sudolocal"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" \
		PEAR_PAM_SUDO_FILE="$pam_file" \
		PEAR_PAM_SUDO_LOCAL_FILE="$pam_local" \
		"$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -eq 0 ]
	grep -q "pam_tid.so" "$pam_local"

	local perms
	perms=$(stat -f "%Lp" "$pam_local" 2>/dev/null || stat -c "%a" "$pam_local" 2>/dev/null)
	[ "$perms" = "444" ]
}

# --- JSON output mode tests ---

@test "pe analyze --json outputs valid JSON with expected fields" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	# Validate it is parseable JSON
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"

	# Check required top-level keys
	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'path' in data, 'missing path'
assert 'overview' in data, 'missing overview'
assert 'entries' in data, 'missing entries'
assert 'total_size' in data, 'missing total_size'
assert 'total_files' in data, 'missing total_files'
assert isinstance(data['entries'], list), 'entries is not a list'
"
}

@test "pe analyze --json entries contain required fields" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data['overview'] is False, 'explicit path should not be overview mode'
for entry in data['entries']:
    assert 'name' in entry, 'entry missing name'
    assert 'path' in entry, 'entry missing path'
    assert 'size' in entry, 'entry missing size'
    assert 'is_dir' in entry, 'entry missing is_dir'
"
}

@test "pe analyze --json path reflects target directory" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data['path'] == '/tmp' or data['path'] == '/private/tmp', \
    f\"unexpected path: {data['path']}\"
"
}

@test "pe analyze --json overview mode returns expected schema" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'path' in data, 'missing path'
assert 'overview' in data, 'missing overview'
assert data['overview'] is True, 'overview scan should have overview: true'
assert 'entries' in data, 'missing entries'
assert 'total_size' in data, 'missing total_size'
assert isinstance(data['entries'], list), 'entries is not a list'
"
}

@test "pe status --json outputs valid JSON with expected fields" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	# Validate it is parseable JSON
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"

	# Check required top-level keys
	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key in ['cpu', 'memory', 'disks', 'health_score', 'host', 'uptime']:
    assert key in data, f'missing key: {key}'
"
}

@test "pe status --json cpu section has expected structure" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cpu = data['cpu']
assert 'usage' in cpu, 'cpu missing usage'
assert 'logical_cpu' in cpu, 'cpu missing logical_cpu'
assert isinstance(cpu['usage'], (int, float)), 'cpu usage is not a number'
"
}

@test "pe status --json memory section has expected structure" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mem = data['memory']
assert 'total' in mem, 'memory missing total'
assert 'used' in mem, 'memory missing used'
assert 'used_percent' in mem, 'memory missing used_percent'
assert mem['total'] > 0, 'memory total should be positive'
"
}

@test "pe status --json piped to stdout auto-detects JSON mode" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	# When piped (not a tty), status should auto-detect and output JSON
	output=$("$STATUS_BIN" 2>/dev/null)
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"
}

@test "pe status --watch streams newline-delimited JSON" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run python3 - "$STATUS_BIN" <<'PY'
import json
import subprocess
import sys

status_bin = sys.argv[1]
proc = subprocess.Popen(
    [status_bin, "--watch", "--interval", "200ms"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
lines = []
try:
    for _ in range(3):
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("missing watch output")
        snapshot = json.loads(line)
        for key in ("collected_at", "cpu", "memory", "disk_io", "network", "health_score"):
            if key not in snapshot:
                raise RuntimeError(f"missing key: {key}")
        lines.append(snapshot)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)

if proc.stderr.read():
    raise RuntimeError("watch wrote to stderr")
print(f"watch_lines={len(lines)}")
PY
	[ "$status" -eq 0 ]
	[[ "$output" == *"watch_lines=3"* ]]
}
