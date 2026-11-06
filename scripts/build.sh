#!/bin/bash
set -euo pipefail

APP_NAME="MoodyVid"
BUNDLE_ID="com.mody.moodyvid"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/Payload/$APP_NAME.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
PYFW="$BUILD_DIR/pyfw"
XC="$PYFW/Python.xcframework"
SLICE="$XC/ios-arm64"
PKGS="$BUILD_DIR/app_packages"

echo "== SDK: $SDK"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR" "$PYFW" "$PKGS"

echo "== Python support package (BeeWare)"
TAG="$(gh release list --repo beeware/Python-Apple-support --limit 100 --json tagName --jq '.[].tagName' | grep '^3\.14' | head -1 || true)"
if [ -z "$TAG" ]; then
  echo "ERROR: no Python 3.14 release found in beeware/Python-Apple-support"
  exit 1
fi
echo "Release: $TAG"
gh release download "$TAG" --repo beeware/Python-Apple-support --pattern 'Python-3.14-iOS-support.*.tar.gz' --dir "$BUILD_DIR"
tar -xzf "$BUILD_DIR"/Python-3.14-iOS-support.*.tar.gz -C "$PYFW"
if [ ! -d "$XC" ]; then
  echo "ERROR: Python.xcframework not found after extraction. Contents:"
  ls -la "$PYFW"
  exit 1
fi

echo "== yt-dlp (nightly build)"
curl -fsSL --retry 3 -o "$BUILD_DIR/yt-dlp" https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp
ls -lh "$BUILD_DIR/yt-dlp"

echo "== Python packages"
python3 -m pip install --quiet --no-deps --target "$PKGS" certifi
if find "$PKGS" -name '*.so' | grep -q .; then
  echo "ERROR: a downloaded package contains macOS native code, which cannot run on iOS:"
  find "$PKGS" -name '*.so'
  exit 1
fi

echo "== Compiling"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -O2 \
  -Wall -Wno-deprecated-declarations \
  -F "$SLICE" \
  -framework UIKit -framework Foundation -framework JavaScriptCore -framework Python -framework Photos \
  -framework AVKit -framework AVFoundation -framework CoreMedia \
  -framework CoreGraphics -framework QuartzCore \
  -Wl,-rpath,@executable_path/Frameworks \
  Sources/*.m \
  -o "$APP_DIR/$APP_NAME"

echo "== Bundle"
cp Resources/Info.plist "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP_DIR/Info.plist"
printf 'APPL????' > "$APP_DIR/PkgInfo"

echo "== Assemble (Python + yt-dlp)"
python3 scripts/assemble.py \
  --app "$APP_DIR" \
  --xcframework "$XC" \
  --packages "$PKGS" \
  --ytdlp "$BUILD_DIR/yt-dlp" \
  --bundle-id "$BUNDLE_ID"

echo "== Binary check"
lipo -info "$APP_DIR/$APP_NAME"
xcrun vtool -show-build "$APP_DIR/$APP_NAME" || true

echo "== Packaging IPA"
( cd "$BUILD_DIR" && zip -qry "$APP_NAME.ipa" Payload )
ls -lh "$BUILD_DIR/$APP_NAME.ipa"
