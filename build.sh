#!/bin/zsh
# Builds DiskDrill.app into ./build (ad-hoc signed, for local use).
#
#   ./build.sh                      # native arch, version 1.0.0
#   VERSION=1.2.0 UNIVERSAL=1 ./build.sh   # arm64 + x86_64 (used by release.sh)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
UNIVERSAL="${UNIVERSAL:-0}"

APP=build/DiskDrill.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

compile() { # arch, output
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$1-apple-macos14.0" \
    Sources/*.swift -o "$2"
}

if [[ "$UNIVERSAL" == "1" ]]; then
  compile arm64 build/obj/DiskDrill-arm64
  compile x86_64 build/obj/DiskDrill-x86_64
  lipo -create build/obj/DiskDrill-arm64 build/obj/DiskDrill-x86_64 -output "$APP/Contents/MacOS/DiskDrill"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/DiskDrill"
fi

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DiskDrill</string>
  <key>CFBundleDisplayName</key><string>DiskDrill</string>
  <key>CFBundleIdentifier</key><string>com.thisbrainai.diskdrill</string>
  <key>CFBundleExecutable</key><string>DiskDrill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 ThisBrainAI LLC</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP ($VERSION build $BUILD_NUMBER)"
