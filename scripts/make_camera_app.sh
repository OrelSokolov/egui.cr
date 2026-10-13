#!/bin/bash
# Wrap a built macOS binary into a minimal .app bundle with an
# NSCameraUsageDescription-bearing Info.plist.
#
# Why: TCC attributes the camera-permission check to the "responsible
# process" — a binary run straight from a shell inherits the terminal's
# identity, and Terminal.app declares no NSCameraUsageDescription, so
# egui_cr_cam_open aborts (the Camera seam returns a clean error first,
# but the OS dialog never appears). Inside a bundle the app itself is
# responsible and the standard permission prompt shows up.
#
# Usage: scripts/make_camera_app.sh [binary] [app-name]
#   scripts/make_camera_app.sh bin/camera Camera
set -euo pipefail
BIN="${1:-bin/camera}"
NAME="${2:-Camera}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/builds/$NAME.app"

[ -x "$ROOT/$BIN" ] || { echo "no such binary: $ROOT/$BIN" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>cr.egui.$NAME</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Shows a live camera preview.</string>
</dict>
</plist>
EOF
echo "$APP — launch with: open $APP"
