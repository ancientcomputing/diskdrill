#!/bin/zsh
# Builds a universal, Developer ID–signed, notarized Folder Drill DMG in ./dist.
#
#   NOTARY_PROFILE=<profile> ./release.sh 1.0.0
#
# NOTARY_PROFILE is a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id MP7PDLDJ96
# Set SKIP_NOTARIZE=1 to build a signed but un-notarized DMG (local testing only).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.0.0}"
# Developer ID Application: ThisBrainAI LLC (MP7PDLDJ96), by fingerprint since the
# keychain may hold several copies of the same certificate.
IDENTITY="${SIGN_IDENTITY:-${IDENTITY:-7D406E47861FFC1D03968EC39F6D703B518ABE02}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

APP=build/FolderDrill.app
DIST=dist
DMG="$DIST/FolderDrill-$VERSION.dmg"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  [[ -n "$NOTARY_PROFILE" ]] || { echo "Set NOTARY_PROFILE (or SKIP_NOTARIZE=1)." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || { echo "notarytool profile '$NOTARY_PROFILE' is not usable." >&2; exit 1; }
fi

echo "==> Building universal app $VERSION (Developer ID, hardened runtime)"
VERSION="$VERSION" UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" SANDBOX=0 ./build.sh
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating DMG"
rm -rf "$DIST/stage" "$DMG"
mkdir -p "$DIST/stage"
ditto "$APP" "$DIST/stage/FolderDrill.app"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "Folder Drill $VERSION" -srcfolder "$DIST/stage" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$DIST/stage"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo "!! Skipped notarization: Gatekeeper will block this DMG on other Macs."
fi

(cd "$DIST" && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")
echo "Done: $PWD/$DMG"
