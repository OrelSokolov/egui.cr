#!/bin/bash
# Phase 1–2 (ANDROID_SUPPORT_PLAN.md): link the Android .so and pack the APK.
# Usage: build_apk.sh <crystal .o file> [extra .o files...]
set -euo pipefail

SDK="$HOME/android-sdk"
BT="$SDK/build-tools/34.0.0"
NDK="$SDK/ndk/25.2.9519653"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API=33
TRIPLE=aarch64-linux-android
LIB=egui_cr_android

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OBJ="${1:?usage: build_apk.sh <crystal.o> [extra.o...]}"; shift
OUTLIB="$HERE/apk/lib/arm64-v8a/lib$LIB.so"
mkdir -p "$HERE/apk/lib/arm64-v8a"

# 1) link the shared library
"$TOOLCHAIN/bin/clang" "--target=$TRIPLE$API" \
  -shared -u ANativeActivity_onCreate \
  -o "$OUTLIB" "$OBJ" "$@" \
  -L"$ROOT/etc/arm64-v8a" \
  -llog -landroid -lEGL -lGLESv3 -lgc -lpcre2-8 -levent -lm

# 2) Java IME bridge → classes.dex (javac + d8; aapt picks up apk/)
mkdir -p "$HERE/classes"
javac --release 8 -cp "$SDK/platforms/android-34/android.jar" \
  -d "$HERE/classes" \
  $(find "$HERE/java" -name '*.java')
# d8 from build-tools 35.0.0: the 34.0.0 build (R8 8.2.2-dev) crashes
# with an internal NPE on some anonymous-class shapes; 35's R8 is fine.
"$SDK/build-tools/35.0.0/d8" --release \
  --lib "$SDK/platforms/android-34/android.jar" \
  --output "$HERE/apk" \
  $(find "$HERE/classes" -name '*.class')

# 3) package APK (hasCode default true: classes.dex present)
"$BT/aapt" package -f \
  -M "$HERE/AndroidManifest.xml" \
  -S "$HERE/res" \
  -I "$SDK/platforms/android-34/android.jar" \
  -F "$HERE/app.unaligned.apk" \
  "$HERE/apk"

# 4) zipalign + sign
"$BT/zipalign" -f 4 "$HERE/app.unaligned.apk" "$HERE/app.apk"
"$BT/apksigner" sign --ks "$HERE/debug.keystore" --ks-pass pass:android \
  --key-pass pass:android "$HERE/app.apk"

echo "APK DONE: $HERE/app.apk"
unzip -l "$HERE/app.apk" | grep -E 'lib/|\.xml|png'
