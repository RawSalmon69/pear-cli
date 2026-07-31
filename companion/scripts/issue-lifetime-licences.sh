#!/usr/bin/env bash
#
# issue-lifetime-licences.sh <recipients-file> [output-dir]
#
# Issues one licence per existing friends-and-family install, so nobody who was
# given Pear auto-updates into a paywall.
#
# This has to happen BEFORE FeatureFlags.paywall is flipped. The bundle ID has
# never changed, so every existing install takes the paid build through the same
# appcast; if their licence does not already exist, their trial simply runs out.
#
# Recipients file: one email per line. Blank lines and #-comments ignored.
# Output: <output-dir>/<email>.pearlicense, one per person, ready to send.
#
# Idempotent: an email whose file already exists is skipped, so re-running after
# adding a name to the list issues only the new one. Order ids are derived from
# the email, so a re-issue for the same person is revocable by the same id.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=license-common.sh
. "$script_dir/license-common.sh"

usage() {
    cat >&2 << 'EOF'
usage: issue-lifetime-licences.sh <recipients-file> [output-dir]

  recipients-file   one email per line; blank lines and # comments ignored
  output-dir        where to write the .pearlicense files (default ./licences)

Order ids are "gift-<email with non-alphanumerics as dashes>", so revoking one
later is: revoke.sh gift-someone-example-com

env: PEAR_LICENSING_DIR, PEAR_LICENCE_MAX_MAJOR, PEAR_OPENSSL (see issue-license.sh)
EOF
    exit 2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi

recipients=$1
out_dir=${2:-licences}

if [[ ! -f $recipients ]]; then
    pear_die "no such recipients file: $recipients"
fi

# Fail before writing anything if the key is missing, rather than part-way
# through a list.
pear_assert_outside_git "$PEAR_LICENSING_DIR"
pear_require_private_key

mkdir -p "$out_dir"

issued=0
skipped=0
failed=0

while IFS= read -r line || [[ -n $line ]]; do
    # Strip a trailing comment, then surrounding whitespace.
    email=${line%%#*}
    email=$(printf '%s' "$email" | tr -d '[:space:]')
    if [[ -z $email ]]; then
        continue
    fi

    if [[ $email != *@*.* ]]; then
        printf 'skip  %-34s (does not look like an email)\n' "$email"
        failed=$((failed + 1))
        continue
    fi

    # Stable, human-legible, and unique per person, so it can be revoked later
    # without keeping a separate ledger.
    slug=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')
    order_id="gift-${slug}"
    target="$out_dir/${email}.pearlicense"

    if [[ -f $target ]]; then
        printf 'have  %-34s %s\n' "$email" "$target"
        skipped=$((skipped + 1))
        continue
    fi

    if "$script_dir/issue-license.sh" "$email" "$order_id" > "$target.tmp" 2> /dev/null; then
        mv "$target.tmp" "$target"
        printf 'issue %-34s %s\n' "$email" "$order_id"
        issued=$((issued + 1))
    else
        rm -f "$target.tmp"
        printf 'FAIL  %-34s (issue-license.sh refused)\n' "$email"
        failed=$((failed + 1))
    fi
done < "$recipients"

printf '\n%d issued, %d already had one, %d failed. Files in %s/\n' \
    "$issued" "$skipped" "$failed" "$out_dir"

if [[ $failed -gt 0 ]]; then
    printf 'Fix the failures before flipping FeatureFlags.paywall.\n'
    exit 1
fi

printf 'Send each file to its recipient (they drop it on the licence pane, or\n'
printf 'paste its contents). Only then flip FeatureFlags.paywall.\n'
