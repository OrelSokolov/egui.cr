#!/bin/bash
# Wrap a built macOS binary into a minimal .app bundle with an
# NSMicrophoneUsageDescription-bearing Info.plist.
#
# Why: TCC attributes the microphone-permission check to the "responsible
# process" — a binary run straight from a shell inherits the terminal's
# identity, and Terminal.app declares no NSMicrophoneUsageDescription, so
# the system never shows the prompt (the shim's egui_cr_mic_perm_request
# prints the explanatory error instead). Inside a bundle the app itself
# is responsible and the standard permission prompt shows up.
#
# Usage: scripts/make_voice_app.sh [binary] [app-name]
#   scripts/make_voice_app.sh bin/voice_echo VoiceEcho
set -euo pipefail
BIN="${1:-bin/voice_echo}"
NAME="${2:-VoiceEcho}"
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
  <key>NSMicrophoneUsageDescription</key><string>Records a short voice clip for the echo test.</string>
</dict>
</plist>
EOF
echo "$APP — launch with: open $APP"
