#!/bin/bash
# make_dmg.sh — package a notarized macOS .app into a distributable DMG.
#
# App-agnostic: the app name and volume label are derived from the bundle,
# and the version is read from the app's Info.plist unless overridden.
#
# Usage:
#   ./make_dmg.sh "/path/to/My App.app" [version] [notary-profile]
#
#   version         defaults to CFBundleShortVersionString from Info.plist
#   notary-profile  defaults to $NOTARY_PROFILE
#
# Environment overrides:
#   NOTARY_PROFILE  notarytool keychain profile name
#   IDENTITY        codesign identity (default "Developer ID Application")
#   OUT_DIR         where to write the DMG (default: current directory)
#
# Prereqs (one time):
#   brew install create-dmg
#   A notarytool keychain profile. Credentials are ACCOUNT-level, not
#   per-app — one profile works for every app on the account:
#     xcrun notarytool store-credentials myprofile \
#         --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#     (password = an app-specific password from account.apple.com)
#
# The .app must already be Developer ID-signed and notarized
# (Xcode Organizer -> Distribute App -> Direct Distribution).

set -euo pipefail

APP="${1:?usage: make_dmg.sh \"/path/to/My App.app\" [version] [notary-profile]}"

[[ -d "$APP" && "$APP" == *.app ]] || { echo "Not an .app bundle: $APP"; exit 1; }
command -v create-dmg >/dev/null || { echo "create-dmg is not installed. Run: brew install create-dmg"; exit 1; }

PLIST="$APP/Contents/Info.plist"
APP_BASENAME="$(basename "$APP")"                 # "My App.app"
APP_NAME="${APP_BASENAME%.app}"                   # "My App"
VER="${2:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)}"
[[ -n "$VER" ]] || { echo "Couldn't read a version from Info.plist; pass one as the second argument."; exit 1; }

PROFILE="${3:-${NOTARY_PROFILE:-}}"
[[ -n "$PROFILE" ]] || {
  echo "No notary profile. Set NOTARY_PROFILE or pass it as the third argument."
  echo "Create one with: xcrun notarytool store-credentials myprofile --apple-id ... --team-id ..."
  exit 1
}

IDENTITY="${IDENTITY:-Developer ID Application}"  # narrows to your single Developer ID cert
OUT_DIR="${OUT_DIR:-.}"
NAME="${APP_NAME// /}-${VER}"                     # spaces stripped for the file name
DMG="${OUT_DIR%/}/${NAME}.dmg"

echo "==> App:     ${APP_NAME} (${VER})"
echo "==> Output:  ${DMG}"
echo "==> Profile: ${PROFILE}"

echo "==> Verifying the app is notarized..."
xcrun stapler validate "$APP" || {
  echo "App is not stapled/notarized. Export it via Organizer -> Direct Distribution first."
  exit 1
}

echo "==> Building ${DMG}..."
rm -f "$DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-size 560 380 \
  --icon-size 128 \
  --icon "$APP_BASENAME" 140 180 \
  --app-drop-link 420 180 \
  --hide-extension "$APP_BASENAME" \
  "$DMG" "$APP"

echo "==> Signing the DMG..."
codesign --force --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the DMG (waits for Apple)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket..."
xcrun stapler staple "$DMG"

echo "==> Verifying..."
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

shasum -a 256 "$DMG" | tee "${DMG}.sha256"
echo "==> Done: ${DMG} (checksum in ${DMG}.sha256)"
