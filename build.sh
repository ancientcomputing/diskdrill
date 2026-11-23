#!/bin/zsh
# Builds build/FolderDrill.app.
#
#   ./build.sh                              native arch, ad-hoc signed (this Mac only)
#   VERSION=1.2.0 UNIVERSAL=1 ./build.sh    arm64 + x86_64 (release.sh, release-mas.sh)
#
# Env:
#   VERSION        CFBundleShortVersionString (default 1.0.0)
#   BUILD_NUMBER   CFBundleVersion (default: the git commit count)
#   UNIVERSAL      1 for an arm64 + x86_64 binary
#   SIGN_IDENTITY  codesigning identity. Default "-" (ad hoc). With a real identity the app is signed
#                  with the hardened runtime and a secure timestamp.
#   SANDBOX        1 to sign with packaging/FolderDrill.entitlements (App Sandbox), as the Mac App
#                  Store requires. The app then asks for a folder to measure on first run.
#   PROVISIONING_PROFILE  a Mac App Store profile to embed (release-mas.sh sets this). Its
#                  application and team identifiers are added to the entitlements.
set -euo pipefail
cd "${0:A:h}"

BUNDLE_ID="ai.thisbrain.folderdrill"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
UNIVERSAL="${UNIVERSAL:-0}"
IDENTITY="${SIGN_IDENTITY:--}"

APP=build/FolderDrill.app
rm -rf "$APP" build/obj build/icon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj build/icon

ENTITLEMENTS=()
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then SANDBOX=1; fi
if [[ "${SANDBOX:-0}" == "1" ]]; then
  cp packaging/FolderDrill.entitlements build/FolderDrill.entitlements
  ENTITLEMENTS=(--entitlements build/FolderDrill.entitlements)
fi
if [[ "$IDENTITY" == "-" ]]; then
  SIGN=(--force --sign -)
else
  SIGN=(--force --options runtime --timestamp --sign "$IDENTITY")
fi

compile() { # arch, output
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$1-apple-macos14.0" \
    Sources/*.swift -o "$2"
}

if [[ "$UNIVERSAL" == "1" ]]; then
  compile arm64 build/obj/FolderDrill-arm64
  compile x86_64 build/obj/FolderDrill-x86_64
  lipo -create build/obj/FolderDrill-arm64 build/obj/FolderDrill-x86_64 -output "$APP/Contents/MacOS/FolderDrill"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/FolderDrill"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon. AppIcon.icns (Finder, Dock) comes from Icon/make_icon.swift. The App Store also wants an
# asset catalog (Assets.car), built here from the same images.
iconutil -c iconset Resources/AppIcon.icns -o build/icon/AppIcon.iconset
CAT=build/icon/Assets.xcassets
mkdir -p "$CAT/AppIcon.appiconset"
echo '{"info":{"author":"xcode","version":1}}' > "$CAT/Contents.json"
images=()
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    name="icon_${pt}x${pt}$([[ $scale == 2 ]] && echo @2x || true).png"
    cp "build/icon/AppIcon.iconset/$name" "$CAT/AppIcon.appiconset/"
    images+=("{\"idiom\":\"mac\",\"size\":\"${pt}x${pt}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"}")
  done
done
echo "{\"images\":[${(j:,:)images}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$CAT/AppIcon.appiconset/Contents.json"
xcrun actool --compile build/icon --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist build/icon/partial.plist \
  --errors --output-format human-readable-text "$CAT" >/dev/null
cp build/icon/Assets.car "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Folder Drill</string>
  <key>CFBundleDisplayName</key><string>Folder Drill</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>FolderDrill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 ThisBrainAI LLC</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
PLIST

if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  # A downloaded profile carries com.apple.quarantine, which App Store Connect rejects (91109).
  xattr -c "$APP/Contents/embedded.provisionprofile"
  # A manual codesign only embeds what's in the entitlements file, and App Store Connect rejects a
  # signature without the application identifier the profile carries.
  PROFILE_PLIST="$(security cms -D -i "$PROVISIONING_PROFILE")"
  APP_ID="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - <<<"$PROFILE_PLIST")"
  TEAM_ID="$(plutil -extract 'Entitlements.com\.apple\.developer\.team-identifier' raw -o - - <<<"$PROFILE_PLIST")"
  [[ "$APP_ID" == *".$BUNDLE_ID" ]] || { echo "error: profile is for $APP_ID, not $BUNDLE_ID" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" build/FolderDrill.entitlements
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" build/FolderDrill.entitlements
fi

find "$APP" -name '._*' -delete
xattr -cr "$APP"
codesign "${SIGN[@]}" "${ENTITLEMENTS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built $PWD/$APP ($VERSION build $BUILD_NUMBER, signed by: $IDENTITY${ENTITLEMENTS:+, sandboxed})"
