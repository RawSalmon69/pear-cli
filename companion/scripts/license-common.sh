#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the Pear licensing scripts. Sourced, never executed.
#
# The owner's Ed25519 private key signs every licence and every revocation list.
# It lives outside this repo and must never enter it: the app verifies with the
# public half and there is no activation server, so one leaked private key is a
# keygen for everybody, forever, with nothing to revoke it against.
#
# Written for the /bin/bash 3.2 that ships with macOS: no mapfile, no associative
# arrays, and every optional step spelled as if/fi rather than `[[ ... ]] && cmd`
# (that form returns 1 when the test fails and trips `set -e`).

# Where the signing key lives. Default is deliberately outside any checkout;
# pear_assert_outside_git enforces that for overrides too.
: "${PEAR_LICENSING_DIR:=$HOME/.pear-licensing}"
PEAR_PRIVATE_KEY="$PEAR_LICENSING_DIR/licence-signing-key.pem"

# Domain separation, identical to SigningDomain in
# companion/Sources/PearCompanion/Licensing/Licence.swift. Changing either side
# without the other invalidates every signature.
PEAR_LICENCE_DOMAIN="pear-licence-v1"
PEAR_REVOCATION_DOMAIN="pear-revocation-v1"

pear_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Absolute form of a path that does not have to exist yet.
pear_abs_path() {
    case $1 in
        /*) printf '%s' "$1" ;;
        *) printf '%s' "$PWD/$1" ;;
    esac
}

# Refuse to keep a signing key inside a git worktree: one `git add -A` and the
# key is public forever. Walks up from the (possibly not yet created) directory
# looking for a .git entry — matching a *file* too, which is how linked worktrees
# such as .claude/worktrees/* are marked.
pear_assert_outside_git() {
    local probe parent
    probe=$(pear_abs_path "$1")
    while :; do
        if [[ -e "$probe/.git" ]]; then
            pear_die "$1 is inside the git repository at $probe. Keep the signing key out of every checkout (set PEAR_LICENSING_DIR)."
        fi
        parent=$(dirname "$probe")
        if [[ "$parent" == "$probe" ]]; then
            return 0
        fi
        probe=$parent
    done
}

# macOS ships LibreSSL as /usr/bin/openssl and LibreSSL cannot do Ed25519 at all,
# so probe for the capability instead of trusting the first openssl on PATH.
pear_find_openssl() {
    local candidate
    for candidate in "${PEAR_OPENSSL:-}" \
        /opt/homebrew/opt/openssl@3/bin/openssl \
        /usr/local/opt/openssl@3/bin/openssl \
        /opt/homebrew/bin/openssl \
        openssl; do
        if [[ -z "$candidate" ]]; then
            continue
        fi
        if ! command -v "$candidate" > /dev/null 2>&1; then
            continue
        fi
        if "$candidate" genpkey -algorithm ed25519 -out /dev/null > /dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

pear_require_openssl() {
    OPENSSL=$(pear_find_openssl) || pear_die "no Ed25519-capable openssl found. The system LibreSSL cannot sign Ed25519: run 'brew install openssl@3', or point PEAR_OPENSSL at one that can."
}

pear_require_private_key() {
    if [[ ! -f "$PEAR_PRIVATE_KEY" ]]; then
        pear_die "no signing key at $PEAR_PRIVATE_KEY. Run scripts/license-keygen.sh first (owner only, once ever)."
    fi
}

pear_make_tmpdir() {
    PEAR_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/pear-licensing.XXXXXX") || pear_die "cannot create a temporary directory"
    trap pear_cleanup_tmpdir EXIT
}

pear_cleanup_tmpdir() {
    if [[ -n "${PEAR_TMPDIR:-}" ]] && [[ -d "$PEAR_TMPDIR" ]]; then
        rm -f "$PEAR_TMPDIR"/*
        rmdir "$PEAR_TMPDIR"
    fi
}

pear_now_iso8601() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# pear_sign_raw <domain> <body-file> <out-file>
#
# Signs "<domain>\n<body>" — the exact bytes SigningDomain.message builds — and
# writes the raw 64-byte signature. OpenSSL's -rawin needs a real file (it
# refuses a pipe it cannot size), hence the temp file.
pear_sign_raw() {
    local domain=$1 body=$2 out=$3
    local message="$PEAR_TMPDIR/message.bin"
    {
        printf '%s\n' "$domain"
        cat "$body"
    } > "$message"
    "$OPENSSL" pkeyutl -sign -inkey "$PEAR_PRIVATE_KEY" -rawin -in "$message" -out "$out" > /dev/null
    rm -f "$message"
}

# pear_sign_base64 <domain> <body-file> -> base64 signature on stdout
pear_sign_base64() {
    local out="$PEAR_TMPDIR/signature.bin"
    pear_sign_raw "$1" "$2" "$out"
    "$OPENSSL" base64 -A -in "$out"
    rm -f "$out"
}
