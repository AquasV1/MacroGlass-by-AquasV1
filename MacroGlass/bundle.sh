#!/bin/bash
#
# Builds MacroGlass.app and signs it with the best identity available.
#
# A bundle buys two things a bare SwiftPM binary can't have:
#
#   1. A stable identity. macOS remembers an Accessibility grant against a
#      code signature. An ad-hoc signature is derived from the code itself,
#      so every rebuild produces a different one and TCC forgets you — which
#      is why the grant keeps needing to be re-ticked. A Developer ID
#      signature is keyed to your team instead, and survives rebuilds.
#   2. A proper foreground app: Dock icon, menu bar, and a window allowed to
#      become key. The app forces that at runtime anyway (see AppDelegate),
#      but with a bundle it never had to.
#
# Usage:
#   ./bundle.sh                 build + sign with the best identity found
#   ./bundle.sh --open          …and launch it
#   MACROGLASS_SIGN_ID="Developer ID Application: You (TEAMID)" ./bundle.sh
#
# For distribution to other people, sign here then run ./notarize.sh.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacroGlass"
BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.macroglass.app"
VERSION="1.5.0"
ENTITLEMENTS="MacroGlass.entitlements"

# ── Pick a signing identity ──────────────────────────────────────────────
#
# A Developer ID Application certificate if one is in the keychain,
# otherwise ad-hoc. Ad-hoc is a real signature — it just has no team behind
# it, so only this Mac trusts it.

SIGN_ID="${MACROGLASS_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/^.*"(.*)".*$/\1/' || true)"
fi

if [ -n "$SIGN_ID" ]; then
    echo "Signing identity: $SIGN_ID"
    HARDENED=1
else
    echo "No Developer ID certificate found — signing ad-hoc."
    SIGN_ID="-"
    HARDENED=0
fi

# ── Build ────────────────────────────────────────────────────────────────

echo "Building release…"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Build produced no binary at $BINARY" >&2
    exit 1
fi

# ── Assemble ─────────────────────────────────────────────────────────────

echo "Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "$BINARY" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MacroGlass runs scripts that can drive other apps.</string>

    <!-- Nothing on macOS claims .ahk or .luau, so they have no registered
         type at all. Declaring them here gives them one, which is what
         lets Finder show "Open With → MacroGlass" and stops other apps'
         open panels treating them as unknown binary. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.macroglass.ahk</string>
            <key>UTTypeDescription</key>
            <string>AutoHotkey Script</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.script</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>ahk</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.macroglass.luau</string>
            <key>UTTypeDescription</key>
            <string>Luau Script</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.script</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>luau</string></array>
            </dict>
        </dict>
    </array>

    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Script</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.macroglass.ahk</string>
                <string>com.macroglass.luau</string>
                <string>public.shell-script</string>
                <string>public.python-script</string>
                <string>com.netscape.javascript-source</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ── Sign ─────────────────────────────────────────────────────────────────
#
# No --deep: it's discouraged by Apple and there's nothing nested here
# anyway, just the one executable.

echo "Signing…"
CODESIGN_ARGS=(--force --sign "$SIGN_ID" --identifier "$BUNDLE_ID")

if [ -f "$ENTITLEMENTS" ]; then
    CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

if [ "$HARDENED" -eq 1 ]; then
    # The hardened runtime and a secure timestamp are both required for
    # notarization. Neither does anything useful for an ad-hoc signature,
    # and --timestamp needs to reach Apple's server, so they're skipped
    # when there's no real certificate.
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${CODESIGN_ARGS[@]}" "$BUNDLE"

# A freshly built app isn't quarantined, but if this tree came out of a
# downloaded zip some files may be. Clear it so nothing inherits it.
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true

# ── Verify and report ────────────────────────────────────────────────────

echo
echo "── Signature ──"
codesign --verify --strict --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/  /'
codesign --display --verbose=2 "$BUNDLE" 2>&1 | grep -E "Authority|TeamIdentifier|Signature" | sed 's/^/  /' || true

echo
echo "── Gatekeeper ──"
if spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/  /'; then
    echo "  Accepted."
else
    echo
    if [ "$HARDENED" -eq 1 ]; then
        echo "  Signed with your Developer ID but not notarized yet."
        echo "  Run ./notarize.sh to finish, then Gatekeeper will accept it"
        echo "  on any Mac."
    else
        echo "  This is expected for an ad-hoc signature, and it does not"
        echo "  stop the app running on this Mac. Gatekeeper only challenges"
        echo "  apps carrying a quarantine flag, which is set by downloading"
        echo "  — an app you just compiled yourself never has one."
        echo
        echo "  It does mean the app can't be handed to anyone else as-is."
        echo "  For that you need an Apple Developer Program membership,"
        echo "  a Developer ID Application certificate, and ./notarize.sh."
    fi
fi

echo
echo "Built ./${BUNDLE}"
echo "Drag it to /Applications, then grant it Accessibility once:"
echo "  System Settings → Privacy & Security → Accessibility"
if [ "$HARDENED" -eq 0 ]; then
    echo
    echo "Note: with an ad-hoc signature the Accessibility grant is tied to"
    echo "this exact build, so it needs re-ticking after each rebuild."
fi
echo

if [ "${1:-}" = "--open" ]; then
    open "$BUNDLE"
fi
