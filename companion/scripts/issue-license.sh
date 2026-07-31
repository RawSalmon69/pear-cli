#!/usr/bin/env bash
#
# issue-license.sh <email> <order-id>
#
# Signs one Pear licence with the owner's Ed25519 key and prints it on stdout.
# One order, one run. Nothing here talks to a network: the app verifies the
# printed string offline against the public key baked into the binary.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=license-common.sh
. "$script_dir/license-common.sh"

usage() {
    cat >&2 << 'EOF'
usage: issue-license.sh <email> <order-id>

Prints one licence string. Send it to the buyer, or save it as
<anything>.pearlicense for them to drop onto the app.

  issue-license.sh buyer@example.com ord_9f2c17 | pbcopy

env:
  PEAR_LICENSING_DIR      where the signing key lives (default ~/.pear-licensing)
  PEAR_LICENCE_MAX_MAJOR  major version the licence covers (default 3, meaning
                          every 3.x update; Pear 4 is a paid upgrade)
  PEAR_OPENSSL            path to an Ed25519-capable openssl
EOF
    exit 2
}

if [[ $# -ne 2 ]]; then
    usage
fi

email=$1
order_id=$2
max_major=${PEAR_LICENCE_MAX_MAJOR:-3}

# Inputs are validated, not escaped. The payload is JSON assembled with printf,
# so a quote or a backslash would produce a signed payload the app cannot parse —
# a licence that fails for the buyer and looks like Pear's bug. Refusing here is
# the honest failure.
if ! [[ $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    pear_die "not an email address: $email"
fi
if ! [[ $order_id =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
    pear_die "order id must be 1-64 characters of A-Za-z0-9 . _ - : $order_id"
fi
if ! [[ $max_major =~ ^[0-9]{1,3}$ ]]; then
    pear_die "PEAR_LICENCE_MAX_MAJOR must be a number: $max_major"
fi

pear_assert_outside_git "$PEAR_LICENSING_DIR"
pear_require_openssl
pear_require_private_key
pear_make_tmpdir

# Key order does not matter: the app verifies and parses these exact bytes rather
# than re-serializing them, which is also why the licence carries the payload
# instead of a JSON field holding its own signature.
payload="$PEAR_TMPDIR/payload.json"
printf '{"email":"%s","orderID":"%s","issuedAt":"%s","maxMajor":%s}' \
    "$email" "$order_id" "$(pear_now_iso8601)" "$max_major" > "$payload"

signature="$PEAR_TMPDIR/signature.bin"
pear_sign_raw "$PEAR_LICENCE_DOMAIN" "$payload" "$signature"

# The licence is base64(signature ‖ payload): one string, no canonicalization to
# disagree about, and the signed bytes travel with the signature.
licence="$PEAR_TMPDIR/licence.bin"
cat "$signature" "$payload" > "$licence"
"$OPENSSL" base64 -A -in "$licence"
printf '\n'
