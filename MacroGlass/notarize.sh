#!/bin/bash
#
# Notarizes MacroGlass.app so Gatekeeper accepts it on somebody else's Mac.
#
# What notarization actually is: you upload the signed app to Apple, an
# automated service scans it for malware, and if it passes you get back a
# ticket. Stapling writes that ticket into the bundle so Gatekeeper can
# check it without a network round-trip. It is not App Review — nobody
# looks at it, and it usually finishes in a couple of minutes.
#
# What it needs, and there's no way around any of it:
#
#   • An Apple Developer Program membership ($99/year)
#   • A "Developer ID Application" certificate in your keychain
#   • Credentials stored in a keychain profile, one time:
#
#       xcrun notarytool store-credentials "macroglass" \
#           --apple-id "you@example.com" \
#           --team-id "YOURTEAMID" \
#           --password "app-specific-password"
#
#     The password is an app-specific one from appleid.apple.com, not your
#     Apple ID password.
#
# Usage:
#   ./bundle.sh && ./notarize.sh
#   NOTARY_PROFILE=other-profile ./notarize.sh

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacroGlass"
BUNDLE="${APP_NAME}.app"
PROFILE="${NOTARY_PROFILE:-macroglass}"

if [ ! -d "$BUNDLE" ]; then
    echo "No ${BUNDLE} here. Run ./bundle.sh first." >&2
    exit 1
fi

# ── Check the signature is notarizable before wasting an upload ──────────

echo "Checking the signature…"

AUTHORITY="$(codesign --display --verbose=2 "$BUNDLE" 2>&1 | grep "^Authority=" | head -1 || true)"
if ! echo "$AUTHORITY" | grep -q "Developer ID Application"; then
    cat >&2 <<'MESSAGE'
This app isn't signed with a Developer ID Application certificate, so
Apple will reject the submission.

An ad-hoc signature (which is what bundle.sh falls back to) can't be
notarized — there's no team identity for Apple to attach a ticket to.

If you have a membership, get the certificate with Xcode:
  Xcode → Settings → Accounts → your Apple ID → Manage Certificates
  → + → Developer ID Application

Then re-run ./bundle.sh; it picks the certificate up automatically.
MESSAGE
    exit 1
fi
echo "  $AUTHORITY"

if ! codesign --display --verbose=2 "$BUNDLE" 2>&1 | grep -q "flags=.*runtime"; then
    echo "The hardened runtime isn't enabled — Apple requires it." >&2
    echo "Re-run ./bundle.sh with the certificate available." >&2
    exit 1
fi
echo "  Hardened runtime: on"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MESSAGE

No notarytool credentials found under the profile "${PROFILE}".

Store them once with:
  xcrun notarytool store-credentials "${PROFILE}" \\
      --apple-id "you@example.com" \\
      --team-id "YOURTEAMID" \\
      --password "app-specific-password"
MESSAGE
    exit 1
fi

# ── Submit ───────────────────────────────────────────────────────────────
#
# notarytool takes a zip, a dmg or a pkg — not a bare .app — and ditto
# preserves the bundle's symlinks and extended attributes, which plain zip
# does not.

ZIP="${APP_NAME}-notarize.zip"
rm -f "$ZIP"
echo
echo "Packing for upload…"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "Submitting to Apple — this usually takes a couple of minutes…"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
    echo >&2
    echo "Submission failed or was rejected. For the details:" >&2
    echo "  xcrun notarytool history --keychain-profile \"$PROFILE\"" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile \"$PROFILE\"" >&2
    rm -f "$ZIP"
    exit 1
fi
rm -f "$ZIP"

# ── Staple ───────────────────────────────────────────────────────────────

echo
echo "Stapling the ticket…"
xcrun stapler staple "$BUNDLE"

echo
echo "── Verification ──"
xcrun stapler validate "$BUNDLE" 2>&1 | sed 's/^/  /'
spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/  /'

# ── Hand it over ─────────────────────────────────────────────────────────

RELEASE="${APP_NAME}.zip"
rm -f "$RELEASE"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$RELEASE"

echo
echo "Done. ./${RELEASE} is notarized and stapled — it will open on any"
echo "Mac without a Gatekeeper warning, including one that has never seen"
echo "it before and is offline."
