#!/usr/bin/env bash
# Refuses to bless a 3.0 paid launch until every precondition actually holds.
#
# FeatureFlags.paywall is one line, and flipping it early is the one change in
# this project that breaks paying customers rather than tests: against a
# placeholder signing key every licence fails to verify, so an early flip locks
# every user out after 14 days with no way to buy back in. This script is the
# gate. Run it, fix what it names, run it again.
#
#   bash companion/scripts/launch-preflight.sh
#
# Exit 0 = safe to flip. Exit 1 = do not flip; the failures are listed.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
licence_swift="$repo_root/companion/Sources/PearCompanion/Licensing/Licence.swift"
flags_swift="$repo_root/companion/Sources/PearCompanion/Support/FeatureFlags.swift"
info_plist="$repo_root/companion/Resources/Info.plist"
pricing_html="$repo_root/site/pricing.html"
privacy_html="$repo_root/site/privacy.html"
revoked_json="${PEAR_REVOKED_JSON:-$repo_root/site/revoked.json}"
key_dir="${PEAR_LICENSING_DIR:-$HOME/.pear-licensing}"
key_file="$key_dir/licence-signing-key.pem"

# The value committed as a placeholder. Its private half was never written to
# disk, so anything still equal to this cannot verify a real licence.
placeholder_key="vVJa64QIOmhmKJnBB+sVOWp/qCb4Cvu/n9PI6AdXvbw="

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
    printf '  FAIL  %s\n' "$1"
    if [[ -n "${2:-}" ]]; then
        printf '        %s\n' "$2"
    fi
    failures=$((failures + 1))
}

printf '\nPear 3.0 launch preflight\n\n'

# 1. The signing key must be real, and its private half reachable, or no licence
#    can be either issued or verified.
if [[ ! -f $licence_swift ]]; then
    fail "Licence.swift not found" "expected at $licence_swift"
else
    baked=$(sed -n 's/.*publicKeyBase64 = "\([^"]*\)".*/\1/p' "$licence_swift" | head -1)
    if [[ -z $baked ]]; then
        fail "could not read LicenceKey.publicKeyBase64" "has the constant been renamed?"
    elif [[ $baked == "$placeholder_key" ]]; then
        fail "the signing key is still the placeholder" \
            "run companion/scripts/license-keygen.sh and paste the printed public key in"
    else
        pass "signing key is not the placeholder"
    fi
fi

if [[ -f $key_file ]]; then
    pass "private key present ($key_file)"
else
    fail "no private key at $key_file" \
        "without it you cannot issue a licence to anyone, including yourself"
fi

# 2. An empty signed revocation list must exist, or every client 404s. That is
#    fail-open and harmless, but it means the refund path was never tested.
if [[ -f $revoked_json ]]; then
    if python3 -c "
import json, sys
d = json.load(open('$revoked_json'))
for k in ('serial', 'issued', 'revoked', 'signature'):
    if k not in d:
        sys.exit('missing key: ' + k)
if not isinstance(d['serial'], int):
    sys.exit('serial is not an integer')
if not d['signature']:
    sys.exit('signature is empty')
" 2> /dev/null; then
        pass "revoked.json present and well formed"
    else
        fail "revoked.json is malformed" "regenerate it with revoke.sh --init"
    fi
else
    fail "no revocation list at $revoked_json" "create it with revoke.sh --init"
fi

# 3. The checkout link has to exist before anyone is asked to buy.
if [[ -f $pricing_html ]]; then
    if grep -q 'PADDLE_CHECKOUT_URL' "$pricing_html"; then
        fail "site/pricing.html still has the [PADDLE_CHECKOUT_URL] placeholder" \
            "the locked state sends people to /pricing, so this is the buy path"
    else
        pass "pricing page has a real checkout link"
    fi
else
    fail "site/pricing.html not found"
fi

# 4. The revocation check is a third network connection, and the policy says two
#    until someone updates it.
if [[ -f $privacy_html ]]; then
    if grep -q 'The app makes three' "$privacy_html"; then
        pass "privacy policy lists three network connections"
    else
        fail "privacy policy does not mention the third network connection" \
            "the weekly refund check is a request the policy must disclose"
    fi
else
    fail "site/privacy.html not found"
fi

# 5. Licences carry maxMajor 3, so a 3.x build must be what ships.
if [[ -f $info_plist ]]; then
    short=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info_plist" 2> /dev/null || echo "")
    case $short in
        3.*) pass "app version is $short, matching maxMajor 3 licences" ;;
        "") fail "could not read CFBundleShortVersionString" ;;
        *) fail "app version is $short, not 3.x" \
            "licences are issued with maxMajor 3; a 2.x build never needed the paywall" ;;
    esac
else
    fail "Info.plist not found"
fi

# 6. Report the flag itself last, so the summary reads as an instruction.
paywall_on=no
if [[ -f $flags_swift ]] && grep -qE 'static let paywall = true' "$flags_swift"; then
    paywall_on=yes
fi

printf '\n'
if [[ $failures -gt 0 ]]; then
    printf 'NOT READY: %d check(s) failed.\n' "$failures"
    if [[ $paywall_on == yes ]]; then
        printf 'FeatureFlags.paywall is ALREADY true. Set it back to false until these pass.\n\n'
    else
        printf 'FeatureFlags.paywall is false. Leave it there.\n\n'
    fi
    exit 1
fi

printf 'All checks passed.\n'
if [[ $paywall_on == yes ]]; then
    printf 'FeatureFlags.paywall is already true. Nothing left to flip.\n\n'
else
    printf 'Remaining, and it is deliberately not automated: issue a licence to every\n'
    printf 'existing install BEFORE flipping FeatureFlags.paywall to true. The bundle ID\n'
    printf 'has never changed, so they auto-update through the same appcast.\n\n'
fi
