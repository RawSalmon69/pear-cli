#!/usr/bin/env bash
#
# revoke.sh <order-id>   — add a refunded order to the public revocation list
# revoke.sh --init       — write the first, empty, signed list
#
# The list is a static signed file deployed with the site. There is no server:
# clients fetch it anonymously at most weekly and ignore it entirely if anything
# about it is wrong. Order ids are hashed because the file is public.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=license-common.sh
. "$script_dir/license-common.sh"

revoked_json=${PEAR_REVOKED_JSON:-$script_dir/../../site/revoked.json}

usage() {
    cat >&2 << 'EOF'
usage: revoke.sh <order-id>
       revoke.sh --init

Adds the sha256 of an order id to revoked.json, bumps the serial, and re-signs.
--init writes an empty signed list (serial 1) and refuses if one already exists.
Commit and deploy the site afterwards; nothing is published by this script.

env:
  PEAR_REVOKED_JSON   list to update (default <repo>/site/revoked.json)
  PEAR_LICENSING_DIR  where the signing key lives (default ~/.pear-licensing)
  PEAR_OPENSSL        path to an Ed25519-capable openssl
EOF
    exit 2
}

mode=add
order_id=""
case ${1:-} in
    --init)
        mode=init
        ;;
    "" | -h | --help | -*)
        usage
        ;;
    *)
        order_id=$1
        ;;
esac

if [[ $# -gt 1 ]]; then
    usage
fi

if [[ $mode == add ]]; then
    if ! [[ $order_id =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        pear_die "order id must be 1-64 characters of A-Za-z0-9 . _ - : $order_id"
    fi
fi

if [[ $mode == init ]] && [[ -e "$revoked_json" ]]; then
    pear_die "$revoked_json already exists. Refusing to replace it — that would un-revoke everyone already in it."
fi

pear_assert_outside_git "$PEAR_LICENSING_DIR"
pear_require_openssl
pear_require_private_key
pear_make_tmpdir

hashes="$PEAR_TMPDIR/hashes.txt"
: > "$hashes"

# Read what is already published. Only this script's own layout is parsed — one
# quoted 64-hex hash per line — so a base64 signature can never be mistaken for
# an entry. The app reads the file with a real JSON parser; this side only has to
# understand the files it wrote.
old_serial=0
if [[ -f "$revoked_json" ]]; then
    parsed_serial=$(sed -n 's/^[[:space:]]*"serial"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$revoked_json" | head -1)
    if [[ -n "$parsed_serial" ]]; then
        old_serial=$parsed_serial
    fi
    sed -n 's/^[[:space:]]*"\([0-9a-f]\{64\}\)",\{0,1\}$/\1/p' "$revoked_json" >> "$hashes"
fi

if [[ $mode == add ]]; then
    new_hash=$(printf '%s' "$order_id" | "$OPENSSL" dgst -sha256 | awk '{print $NF}')
    if grep -qx "$new_hash" "$hashes"; then
        printf 'already revoked: %s (serial %s, nothing written)\n' "$order_id" "$old_serial"
        exit 0
    fi
    printf '%s\n' "$new_hash" >> "$hashes"
fi

sort -u "$hashes" > "$hashes.sorted"
mv "$hashes.sorted" "$hashes"

new_serial=$((old_serial + 1))
issued=$(pear_now_iso8601)

# The canonical payload the signature covers, byte for byte the same thing
# RevocationList.canonicalBody builds: "serial=N\nissued=…" then one
# "\nrevoked=<hash>" per entry, no trailing newline, in the file's own order.
body="$PEAR_TMPDIR/body.txt"
{
    printf 'serial=%s\n' "$new_serial"
    printf 'issued=%s' "$issued"
    while IFS= read -r hash; do
        printf '\nrevoked=%s' "$hash"
    done < "$hashes"
} > "$body"

signature=$(pear_sign_base64 "$PEAR_REVOCATION_DOMAIN" "$body")

# Written from the same sorted file, in the same order, so the JSON and the
# signed payload cannot drift apart.
count=$(wc -l < "$hashes")
count=${count// /}
staged="$PEAR_TMPDIR/revoked.json"
{
    printf '{\n'
    printf '  "serial": %s,\n' "$new_serial"
    printf '  "issued": "%s",\n' "$issued"
    if [[ $count -eq 0 ]]; then
        printf '  "revoked": [],\n'
    else
        printf '  "revoked": [\n'
        index=0
        while IFS= read -r hash; do
            index=$((index + 1))
            if [[ $index -lt $count ]]; then
                printf '    "%s",\n' "$hash"
            else
                printf '    "%s"\n' "$hash"
            fi
        done < "$hashes"
        printf '  ],\n'
    fi
    printf '  "signature": "%s"\n' "$signature"
    printf '}\n'
} > "$staged"

mkdir -p "$(dirname "$revoked_json")"
mv "$staged" "$revoked_json"

printf 'wrote %s\n' "$revoked_json"
printf '  serial: %s (was %s)\n' "$new_serial" "$old_serial"
printf '  entries: %s\n' "$count"
printf 'Commit it and deploy the site. Clients pick it up within a week.\n'
