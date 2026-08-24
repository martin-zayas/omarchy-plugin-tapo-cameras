#!/usr/bin/env bash
# ==============================================================================
# TAPO Cameras installer for Omarchy 4 (Quickshell / omarchy-shell).
#
# Installs the plugin via `omarchy plugin add`, checks RTSP dependencies,
# installs the tapo-cameras CLI, and restarts the shell.
#
# Dependencies: qt6-multimedia, gst-plugins-good, gst-libav (RTSP decode).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="martin-zayas-tapo-cameras"
CLI_SRC="$SCRIPT_DIR/tapo-cameras"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

echo "=== TAPO Cameras installer (Omarchy 4 / Quickshell) ==="

if ! command -v pacman >/dev/null 2>&1; then
  echo "This installer expects a pacman-based system (Arch/Omarchy)." >&2
  exit 1
fi

if ! command -v omarchy-shell >/dev/null 2>&1 || ! command -v omarchy-plugin-add >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: omarchy-shell / omarchy-plugin-add not found on PATH.
TAPO Cameras requires Omarchy 4+.
MSG
  exit 1
fi

for f in "$SCRIPT_DIR/manifest.json" "$SCRIPT_DIR/Service.qml" \
         "$SCRIPT_DIR/BarWidget.qml" "$SCRIPT_DIR/Panel.qml" "$CLI_SRC"; do
  [ -f "$f" ] || { echo "Missing installer asset: $f" >&2; exit 1; }
done

MISSING_PKGS=()
pacman -Qq qt6-multimedia   >/dev/null 2>&1 || MISSING_PKGS+=("qt6-multimedia")
pacman -Qq gst-plugins-good >/dev/null 2>&1 || MISSING_PKGS+=("gst-plugins-good")
pacman -Qq gst-libav        >/dev/null 2>&1 || MISSING_PKGS+=("gst-libav")

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing required packages: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed "${MISSING_PKGS[@]}"
else
  echo "✓ Dependencies present (qt6-multimedia, gst-plugins-good, gst-libav)"
fi

interactive() { [ -t 0 ] && [ -t 1 ]; }
PLACEMENT_CHOSEN=0

install_plugin() {
  if [ "$SCRIPT_DIR" = "$PLUGIN_DIR" ]; then
    echo "✓ Running from the installed plugin — leaving it alone"
    omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
    return
  fi

  if [ -e "$PLUGIN_DIR" ] || [ -L "$PLUGIN_DIR" ]; then
    if [ -d "$PLUGIN_DIR/.git" ]; then
      echo "✓ Plugin already installed as a git checkout"
      echo "  Update it with: omarchy plugin update $PLUGIN_ID"
      return
    fi
    if [ -L "$PLUGIN_DIR" ]; then
      echo "✓ Plugin is a dev symlink — leaving it alone"
      return
    fi
    if [ -f "$PLUGIN_DIR/manifest.json" ] &&
       [ "$(jq -r '.id // ""' "$PLUGIN_DIR/manifest.json")" = "$PLUGIN_ID" ]; then
      echo "→ Replacing a legacy copy-install with a git checkout"
      rm -rf "$PLUGIN_DIR"
    else
      echo "⚠️  $PLUGIN_DIR exists and is not this plugin — leaving it alone." >&2
      return
    fi
  fi

  local url
  url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "$SCRIPT_DIR")"
  echo "→ Adding the plugin from $url"
  if interactive; then
    omarchy plugin add "$url" --enable
    PLACEMENT_CHOSEN=1
  else
    omarchy plugin add "$url" --enable --yes
  fi
}
install_plugin

place_widget() {
  if (( PLACEMENT_CHOSEN )); then return 0; fi
  local want current
  want="$(jq -r '.barWidget.defaultSection // "right"' "$SCRIPT_DIR/manifest.json")"
  current="$(jq -r --arg id "$PLUGIN_ID" '
      .bar.layout // {} | to_entries[]
      | select(.value | any(.id == $id)) | .key' \
      "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2>/dev/null || true)"
  [ -n "$current" ] || return 0
  [ "$current" != "$want" ] || return 0
  omarchy bar move "$PLUGIN_ID" --section "$want" >/dev/null 2>&1 &&
    echo "✓ Moved the bar widget to the $want section"
}
place_widget

install -D -m 755 "$CLI_SRC" "$HOME/.local/bin/tapo-cameras"
echo "✓ CLI installed to ~/.local/bin/tapo-cameras"

echo
echo "Restarting omarchy-shell to load the plugin…"
omarchy-restart-shell >/dev/null 2>&1 || \
  echo "⚠️  Restart omarchy-shell manually (omarchy-restart-shell)."
echo "✓ Shell restarted"

cat <<EOF

=== Install complete ===

✓ Bar widget added — click the camera icon in the bar to configure cameras
✓ CLI: tapo-cameras

Quick start:
  1. Open the Tapo app → Camera Settings → Advanced → Camera Account
  2. Click the camera icon in the bar → Add camera (host, RTSP path /stream2)
  3. Select a camera from the list to start the PiP stream

Test RTSP before configuring:
  ffplay -rtsp_transport tcp rtsp://USER:PASS@IP:554/stream2

Updating later:  omarchy plugin update $PLUGIN_ID
Removing:        omarchy plugin remove $PLUGIN_ID
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
