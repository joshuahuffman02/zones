#!/bin/zsh
# Builds Zones.app into ./build and signs it with a stable identity, so the Accessibility permission
# survives rebuilds and updates (an ad-hoc signature changes every build).
#
#   ./build.sh            build and sign
#   ./build.sh --run      build, sign, quit any running copy, and launch
#
#   BUILD=7 ./build.sh    set the build number (release.sh does this)
#   SIGN_ID=<sha1 or name> ./build.sh   pick a signing identity; otherwise .signing-identity, then the
#                                       first "Apple Development" identity
set -euo pipefail
cd "${0:A:h}"

BUILD="${BUILD:-0}"
VERSION="1.0.$BUILD"
FEED="https://github.com/joshuahuffman02/zones/releases/latest/download/appcast.xml"
ED_KEY="2LbiRAleeyijgVHuM2l3KvK42tl6XcYDVNUQ51+hKTI="

swift build -c release --product Zones
BIN="$(swift build -c release --show-bin-path)/Zones"

APP=build/Zones.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Zones"
# Sparkle (auto-updates) ships as a framework next to the app.
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.strip.zones</string>
  <key>CFBundleName</key><string>Zones</string>
  <key>CFBundleDisplayName</key><string>Zones</string>
  <key>CFBundleExecutable</key><string>Zones</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST

# Signing identity: SIGN_ID, else the one saved in .signing-identity, else the first Apple Development one.
if [[ -z "${SIGN_ID:-}" && -f .signing-identity ]]; then SIGN_ID="$(<.signing-identity)"; fi
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -n "$SIGN_ID" ]]; then
  SIGN=(codesign --force --options runtime --sign "$SIGN_ID")
else
  echo "No signing identity found; signing ad-hoc. Accessibility must be re-granted after each rebuild." >&2
  SIGN=(codesign --force --sign -)
fi
# Inside out: Sparkle's helpers, the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
  [[ -e "$part" ]] && "${SIGN[@]}" "$part"
done
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $PWD/$APP ($VERSION)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -TERM -x Zones 2>/dev/null && sleep 1 || true
  open "$APP"
fi
