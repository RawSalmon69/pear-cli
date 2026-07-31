#!/usr/bin/env bash
#
# license-keygen.sh                — create the owner's Ed25519 signing key (once, ever)
# license-keygen.sh --public-key   — reprint the public key for pasting into the app
#
# Owner step, run on the owner's Mac. The private key never leaves
# $PEAR_LICENSING_DIR and is never printed by anything in this repo.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=license-common.sh
. "$script_dir/license-common.sh"

usage() {
    cat >&2 << 'EOF'
usage: license-keygen.sh [--public-key]

  (no arguments)  create the signing key, then print the public key to paste
                  into companion/Sources/PearCompanion/Licensing/Licence.swift
  --public-key    print the existing public key and nothing else

env:
  PEAR_LICENSING_DIR  where the key lives (default ~/.pear-licensing, and it may
                      not be inside any git checkout)
  PEAR_OPENSSL        path to an Ed25519-capable openssl
EOF
    exit 2
}

mode=create
case ${1:-} in
    "") mode=create ;;
    --public-key) mode=print ;;
    *) usage ;;
esac

pear_assert_outside_git "$PEAR_LICENSING_DIR"
pear_require_openssl

if [[ $mode == create ]]; then
    # Refuse to overwrite: every licence ever issued verifies against the public
    # half of the existing key, and a new key silently invalidates all of them.
    if [[ -e "$PEAR_PRIVATE_KEY" ]]; then
        pear_die "a signing key already exists at $PEAR_PRIVATE_KEY. Refusing to overwrite it — every licence already issued verifies against its public half."
    fi
    mkdir -p "$PEAR_LICENSING_DIR"
    chmod 700 "$PEAR_LICENSING_DIR"
    (
        umask 077
        "$OPENSSL" genpkey -algorithm ed25519 -out "$PEAR_PRIVATE_KEY"
    )
    chmod 600 "$PEAR_PRIVATE_KEY"
fi

pear_require_private_key

# The app bakes in the 32 raw bytes of the public key; a DER SPKI is those bytes
# with a 12-byte header.
public_key=$("$OPENSSL" pkey -in "$PEAR_PRIVATE_KEY" -pubout -outform DER | tail -c 32 | "$OPENSSL" base64 -A)

if [[ $mode == print ]]; then
    printf '%s\n' "$public_key"
    exit 0
fi

cat << EOF
Signing key written to $PEAR_PRIVATE_KEY
Back that directory up offline. Never copy it anywhere else, and never commit it.

Paste the public key into
companion/Sources/PearCompanion/Licensing/Licence.swift, replacing the
placeholder in LicenceKey:

    static let publicKeyBase64 = "$public_key"

Then run 'swift test' in companion/ — testBakedInPublicKeyParses catches a bad
paste. Issue licences with scripts/issue-license.sh.
EOF
