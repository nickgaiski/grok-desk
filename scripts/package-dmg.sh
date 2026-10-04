#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Grok Desk.app}"
[[ -d "$app" ]] || { echo "Build the app with bash scripts/package-app.sh first." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$root/dist/Grok-Desk-$version-preview.dmg"
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
staging=$(mktemp -d /tmp/grok-dmg.XXXXXX)
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/Grok Desk.app"
ln -s /Applications "$staging/Applications"
ln -s '/System/Applications/System Settings.app' "$staging/System Settings"
cp "$root/packaging/First launch.html" "$staging/First launch.html"
python3 - "$staging/Privacy & Security.webloc" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'URL':'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension'},f)
PY
mkdir -p "$root/dist"
hdiutil create -volname 'Grok Desk Preview' -srcfolder "$staging" -format UDZO "$output"
hdiutil verify "$output"
(cd "$root/dist" && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
printf '%s\n' "$output"
