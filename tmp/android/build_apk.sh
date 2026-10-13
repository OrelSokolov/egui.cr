#!/bin/bash
# Phase 1–2 (ANDROID_SUPPORT_PLAN.md): link the Android .so and pack the APK.
# Usage: build_apk.sh <crystal .o file> [extra .o files...]
set -euo pipefail

# Host-portable: Linux box (~/android-sdk) or macOS (~/Library/Android/sdk).
SDK="${ANDROID_SDK:-$HOME/android-sdk}"
[ -d "$SDK" ] || SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/34.0.0"
NDK="$SDK/ndk/25.2.9519653"
case "$(uname -s)" in
  Darwin) PREBUILT=darwin-x86_64 ;;
  *)      PREBUILT=linux-x86_64 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$PREBUILT"
API=33
TRIPLE=aarch64-linux-android
LIB=egui_cr_android

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."

# Java: prefer the JDK downloaded into tmp/android/dl; fall back to a
# WORKING system java (on macOS /usr/bin/java is a stub that exists on
# PATH but errors out, so probe with -version, not command -v).
JDK_DIR="$(find "$HERE/dl" -maxdepth 1 -name 'jdk-*' -type d | head -1)"
if [ -n "$JDK_DIR" ] && [ -x "$JDK_DIR/Contents/Home/bin/java" ]; then
  export JAVA_HOME="$JDK_DIR/Contents/Home"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
java -version >/dev/null 2>&1 || { echo "ERROR: no working java (put a JDK into $HERE/dl)"; exit 1; }

# Debug keystore (password "android", the ADT-standard one)
if [ ! -f "$HERE/debug.keystore" ]; then
  keytool -genkeypair -keystore "$HERE/debug.keystore" -storepass android \
    -keypass android -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
    -keyalg RSA -keysize 2048 -validity 10000
fi

OBJ="${1:?usage: build_apk.sh <crystal.o> [extra.o...]}"; shift
OUTLIB="$HERE/apk/lib/arm64-v8a/lib$LIB.so"
mkdir -p "$HERE/apk/lib/arm64-v8a"

# 1) link the shared library
"$TOOLCHAIN/bin/clang" "--target=$TRIPLE$API" \
  -shared -u ANativeActivity_onCreate \
  -o "$OUTLIB" "$OBJ" "$@" \
  -L"$ROOT/etc/arm64-v8a" \
  -llog -landroid -lEGL -lGLESv3 -lcamera2ndk -lmediandk -lz -lgc -lpcre2-8 -levent -lm

# 2) Java IME bridge → classes.dex (javac + d8; aapt picks up apk/)
mkdir -p "$HERE/classes"
javac --release 8 -cp "$SDK/platforms/android-34/android.jar" \
  -d "$HERE/classes" \
  $(find "$HERE/java" -name '*.java')
# d8: prefer build-tools 35 (the 34 R8 8.2.2-dev crashed on some
# anonymous-class shapes on Linux); fall back to 34 when 35 is absent.
D8="$SDK/build-tools/35.0.0/d8"
[ -x "$D8" ] || D8="$BT/d8"
"$D8" --release \
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
