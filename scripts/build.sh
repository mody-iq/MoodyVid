#!/bin/bash
set -euo pipefail

APP_NAME="MoodyVid"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/Payload/$APP_NAME.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "== SDK: $SDK"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"

echo "== Compiling"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -O2 \
  -Wall -Wno-deprecated-declarations \
  -framework UIKit -framework Foundation \
  Sources/*.m \
  -o "$APP_DIR/$APP_NAME"

echo "== Bundle"
cp Resources/Info.plist "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP_DIR/Info.plist"
printf 'APPL????' > "$APP_DIR/PkgInfo"

echo "== Binary check"
lipo -info "$APP_DIR/$APP_NAME"
xcrun vtool -show-build "$APP_DIR/$APP_NAME" || true

echo "== Packaging IPA"
( cd "$BUILD_DIR" && zip -qry "$APP_NAME.ipa" Payload )
ls -lh "$BUILD_DIR/$APP_NAME.ipa"
