#!/bin/zsh
# build.sh — builds ThermalMonitor.app and a drag-to-install DMG.
#
# HOW TO RUN (from the project folder):
#   ./build.sh            release build → dist/ThermalMonitor.app + dist/ThermalMonitor-<ver>-<timestamp>.dmg
#   ./build.sh --help
#
# Uses only built-in tools: swift, iconutil, codesign (ad-hoc, not notarized), hdiutil.
# Never deletes anything: each DMG gets a unique timestamped name and its own staging folder
# under .build/dmg-staging/<timestamp>/; the .app in dist/ is updated in place.

set -euo pipefail

VERSION="0.2.3"
BUNDLE_ID="io.github.dan-robotics.ThermalMonitor"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

cd "$(dirname "$0")"
STAMP="$(date +%Y%m%d-%H%M%S)"
APP="dist/ThermalMonitor.app"
DMG="dist/ThermalMonitor-${VERSION}-${STAMP}.dmg"
STAGING=".build/dmg-staging/${STAMP}"

echo "▶ 1/4  swift build (release)"
swift build -c release --product ThermalMonitor
BIN="$(swift build -c release --product ThermalMonitor --show-bin-path)/ThermalMonitor"

echo "▶ 2/4  assemble ${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" Resources
# App icon: drawn by tools/make-icon.swift, rebuilt only when the drawing code changes.
if [[ ! -f Resources/AppIcon.icns || tools/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  echo "       drawing app icon"
  swift tools/make-icon.swift .build/icon/AppIcon.iconset
  iconutil -c icns .build/icon/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp -f Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
cp -f "${BIN}" "${APP}/Contents/MacOS/ThermalMonitor"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ThermalMonitor</string>
  <key>CFBundleDisplayName</key><string>ThermalMonitor</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ThermalMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${STAMP}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Daniel Andries</string>
</dict>
</plist>
PLIST

echo "▶ 3/4  ad-hoc codesign (first open on another Mac: System Settings › Privacy & Security › Open Anyway)"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --verbose=1 "${APP}"

echo "▶ 4/4  DMG → ${DMG}"
mkdir -p "${STAGING}"
ditto "${APP}" "${STAGING}/ThermalMonitor.app"
ln -sf /Applications "${STAGING}/Applications"
hdiutil create -volname "ThermalMonitor" -srcfolder "${STAGING}" -format UDZO -fs HFS+ "${DMG}" >/dev/null

echo ""
echo "✔ Built:"
echo "   App: $(pwd)/${APP}"
echo "   DMG: $(pwd)/${DMG}"
echo "   Run: open \"${APP}\"   (or open the DMG and drag ThermalMonitor to Applications)"
