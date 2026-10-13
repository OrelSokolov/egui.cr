#!/bin/bash
# Wrap a built macOS binary into a minimal .app bundle with an
# NSMicrophoneUsageDescription-bearing Info.plist.
#
# Why: CoreAudio delivers digital silence to processes without mic
# authorization, and a binary run straight from a shell inherits the
# terminal's identity — the TCC dialog never appears for it. Inside a
# bundle the app itself is responsible: the first Microphone.open pops
# the standard permission prompt (backend/audio.cr → egui_cr_mic_perm).
#
# Usage: scripts/make_audio_app.sh [binary] [app-name]
#   scripts/make_audio_app.sh bin/audio Audio
set -euo pipefail
BIN="${1:-bin/audio}"
NAME="${2:-Audio}"
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
  <key>NSMicrophoneUsageDescription</key><string>Records a short microphone clip for the echo test and shows its live waveform.</string>
</dict>
</plist>
EOF
echo "$APP — launch with: open $APP"
