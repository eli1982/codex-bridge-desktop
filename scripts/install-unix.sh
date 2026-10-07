#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
for dependency in node npm git python3 cloudflared; do
  command -v "$dependency" >/dev/null || { echo "Missing $dependency. See README.md prerequisites." >&2; exit 1; }
done
node -e 'let v=process.versions.node.split(".").map(Number); if(v[0]<20 || (v[0]===20 && v[1]<12) || v[0]>=27) process.exit(1)' ||
  { echo "Node.js 20.12 through 26.x is required for pinned DevSpace 1.0.2." >&2; exit 1; }
npm_prefix="$HOME/.local/share/codex-bridge-desktop/npm"
package_path="$npm_prefix/node_modules/@waishnav/devspace/package.json"
if [[ -f "$package_path" ]]; then
  installed="$(node -p "require(process.argv[1]).version" "$package_path")"
  [[ "$installed" == "1.0.2" ]] || { echo "Existing local DevSpace $installed differs from required 1.0.2." >&2; exit 1; }
else
  mkdir -p "$npm_prefix"
  npm install --prefix "$npm_prefix" @waishnav/devspace@1.0.2
fi
devspace_bin="$npm_prefix/node_modules/.bin/devspace"
[[ -x "$devspace_bin" ]] || { echo "Pinned DevSpace executable was not installed." >&2; exit 1; }
"$repo/scripts/build-unix.sh"
case "$(uname -s)" in Darwin) platform=macos ;; Linux) platform=ubuntu ;; esac
project=""
if [[ "$#" -gt 0 ]]; then project="$1"; fi
if [[ -z "$project" ]]; then
  read -r -p "Project folder to expose while bridge is on: " project
fi
if [[ "$platform" == macos ]]; then
  destination="$HOME/Applications/Codex Bridge.app"
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  [[ ! -e "$destination" ]] || { echo "Close and remove the previous beta app before installing." >&2; exit 1; }
  cp -R "$repo/dist/macos/Codex Bridge.app" "$destination"
  cp "$repo/dist/macos/codex-bridge" "$HOME/.local/bin/codex-bridge"
else
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"
  cp "$repo/dist/ubuntu/codex-bridge" "$HOME/.local/bin/codex-bridge"
  cp "$repo/dist/ubuntu/bridge-on.png" "$HOME/.local/share/icons/codex-bridge.png"
  sed "s|^Exec=.*|Exec=\"$HOME/.local/bin/codex-bridge\" menu|; s|^Icon=.*|Icon=$HOME/.local/share/icons/codex-bridge.png|" \
    "$repo/dist/ubuntu/codex-bridge.desktop" > "$HOME/.local/share/applications/codex-bridge.desktop"
fi
chmod +x "$HOME/.local/bin/codex-bridge"
"$HOME/.local/bin/codex-bridge" configure --root "$project" --devspace-command "$devspace_bin"
echo "Installed. The bridge is OFF. Launch Codex Bridge to turn it on."