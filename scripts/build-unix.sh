#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  Darwin) platform=macos ;;
  Linux) platform=ubuntu ;;
  *) echo "Build on macOS or Linux." >&2; exit 1 ;;
esac
python3 -m venv "$repo/.build-venv"
"$repo/.build-venv/bin/python" -m pip install --disable-pip-version-check -r "$repo/unix/build-requirements.txt"
"$repo/.build-venv/bin/python" -m PyInstaller --noconfirm --clean --onefile \
  --name codex-bridge --distpath "$repo/dist/$platform" \
  --workpath "$repo/.build-work" --specpath "$repo/.build-work" "$repo/unix/bridge.py"
if [[ "$platform" == ubuntu ]]; then
  cp "$repo/windows/bridge-icons/bridge-on.png" "$repo/dist/ubuntu/bridge-on.png"
  cat > "$repo/dist/ubuntu/codex-bridge.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Codex Bridge
Comment=Control a local DevSpace bridge
Exec=codex-bridge menu
Terminal=true
Icon=codex-bridge
Categories=Development;
DESKTOP
else
  app="$repo/dist/macos/Codex Bridge.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$repo/dist/macos/codex-bridge" "$app/Contents/Resources/codex-bridge"
  cat > "$app/Contents/MacOS/Codex Bridge" <<'LAUNCHER'
#!/bin/sh
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
command_file="$app_dir/Resources/codex-bridge.command"
exec /usr/bin/open -a Terminal "$command_file"
LAUNCHER
  cat > "$app/Contents/Resources/codex-bridge.command" <<'COMMAND'
#!/bin/sh
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$app_dir/Resources/codex-bridge" menu
COMMAND
  chmod +x "$app/Contents/MacOS/Codex Bridge" "$app/Contents/Resources/codex-bridge.command"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Codex Bridge</string>
<key>CFBundleIdentifier</key><string>io.github.codex-bridge-desktop.beta</string>
<key>CFBundleExecutable</key><string>Codex Bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  iconset="$repo/.build-work/Bridge.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    doubled=$((size * 2))
    sips -z "$size" "$size" "$repo/windows/bridge-icons/bridge-on.png" --out "$iconset/icon_"$size"x"$size".png" >/dev/null
    sips -z "$doubled" "$doubled" "$repo/windows/bridge-icons/bridge-on.png" --out "$iconset/icon_"$size"x"$size"@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/Bridge.icns"
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as stream: data = plistlib.load(stream)
data["CFBundleIconFile"] = "Bridge"
with open(path, "wb") as stream: plistlib.dump(data, stream)
PY
fi
echo "Built $platform binary in $repo/dist/$platform"