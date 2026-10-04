#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${GROK_BUILD_DIR:-/tmp/grok-desk-release}"
export TMPDIR=/tmp
export CLANG_MODULE_CACHE_PATH=/tmp/grok-clang-cache
cd "$project_root"
bash scripts/build-shaders.sh
swift build -c release --disable-sandbox --cache-path /tmp/grok-desk-cache --scratch-path "$build_root"
app_path="$project_root/dist/Grok Desk.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers"
cp "$build_root/release/GrokDesk" "$app_path/Contents/MacOS/GrokDesk"
cp "$build_root/release/GrokDeskRoutineRunner" "$app_path/Contents/Helpers/GrokDeskRoutineRunner"
codesign --force --sign - "$app_path/Contents/Helpers/GrokDeskRoutineRunner"
cp -R "$build_root/release/GrokDesk_GrokDesk.bundle" "$app_path/Contents/Resources/"
cp "$project_root/docs/THIRD-PARTY-NOTICES.txt" "$app_path/Contents/Resources/"
if [ -d "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle" ]; then chmod -R u+w "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle"; fi
cp -R "$build_root/release/SwiftTerm_SwiftTerm.bundle" "$app_path/Contents/Resources/"
icon_path="${GROK_APP_ICON:-$project_root/resources/icon.icns}"
if [ -f "$icon_path" ]; then cp "$icon_path" "$app_path/Contents/Resources/AppIcon.icns"; fi
/usr/bin/python3 - "$app_path/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleExecutable':'GrokDesk', 'CFBundleIdentifier':'dev.jarvis.grok-desk',
        'CFBundleName':'Grok Desk', 'CFBundleDisplayName':'Grok Desk',
        'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.8.6',
        'CFBundleVersion':'13', 'CFBundleIconFile':'AppIcon',
        'NSHighResolutionCapable':True, 'LSMinimumSystemVersion':'14.0',
        'NSAppleEventsUsageDescription':'Grok Desk opens the official Grok authorization manager in Terminal when you choose Authorize.',
        'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    }, output)
PY
codesign --force --sign - "$app_path"
printf '%s\n' "$app_path"
