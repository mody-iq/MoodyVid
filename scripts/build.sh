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

echo "== LAME (static MP3 encoder for iOS)"
LAME_DIR="$BUILD_DIR/lame"
LAME_TAR="$BUILD_DIR/lame.tar.gz"
LAME_VER="3.100"
curl -fsSL --retry 3 -o "$LAME_TAR" "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-${LAME_VER}.tar.gz"
mkdir -p "$LAME_DIR"
tar -xzf "$LAME_TAR" -C "$LAME_DIR" --strip-components=1
(
  cd "$LAME_DIR"
  ./configure \
    --host=aarch64-apple-darwin \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    --disable-decoder \
    --disable-analyzer-hacks \
    --disable-debug \
    --disable-asm \
    CC="xcrun --sdk iphoneos clang -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0" \
    RANLIB="xcrun --sdk iphoneos ranlib" \
    AR="xcrun --sdk iphoneos ar" \
    >/dev/null
  make -j4 >/dev/null
)
if [ ! -f "$LAME_DIR/libmp3lame/.libs/libmp3lame.a" ]; then
  echo "ERROR: LAME failed to build"
  exit 1
fi
echo "LAME built: $LAME_DIR/libmp3lame/.libs/libmp3lame.a"

echo "== Compiling"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -O2 \
  -Wall -Wno-deprecated-declarations \
  -F "$SLICE" \
  -I "$LAME_DIR" \
  -framework UIKit -framework Foundation -framework JavaScriptCore -framework Python -framework Photos \
  -framework AVKit -framework AVFoundation -framework CoreMedia -framework AudioToolbox \
  -framework CoreGraphics -framework QuartzCore -framework WebKit \
  -framework UserNotifications -framework StoreKit -framework MediaPlayer \
  -Wl,-rpath,@executable_path/Frameworks \
  Sources/*.m \
  "$LAME_DIR/libmp3lame/.libs/libmp3lame.a" \
  -o "$APP_DIR/$APP_NAME"

echo "== Bundle"
cp Resources/Info.plist "$APP_DIR/Info.plist"

# The icon is drawn, not committed, so the repository carries no binary and the
# icon stays sharp at any size. 1024 is the App Store size; iOS downsamples it.
echo "== App icon"
python3 scripts/make_icon.py "$APP_DIR/AppIcon.png" 1024
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP_DIR/Info.plist"
printf 'APPL????' > "$APP_DIR/PkgInfo"

# Profile pictures shown on the Contact sheet, copied next to the icon so the
# app can load them from its own bundle.
echo "== Contact avatars"
if [ -d Resources/avatars ]; then
  mkdir -p "$APP_DIR/avatars"
  cp Resources/avatars/*.png "$APP_DIR/avatars/" 2>/dev/null || true
fi

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
