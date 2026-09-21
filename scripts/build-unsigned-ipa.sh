#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT:?}"' EXIT

cd "$ROOT"
xcodegen generate
xcodebuild build \
  -project SimpleCameraAutoSender.xcodeproj \
  -scheme SimpleCameraAutoSender \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

mkdir -p "$BUILD_ROOT/Payload" "$ROOT/dist"
cp -R \
  "$BUILD_ROOT/build/Build/Products/Release-iphoneos/SimpleCameraAutoSender.app" \
  "$BUILD_ROOT/Payload/"
APP_BUNDLE="$BUILD_ROOT/Payload/SimpleCameraAutoSender.app"
test -f "$APP_BUNDLE/Assets.car"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons' "$APP_BUNDLE/Info.plist" >/dev/null
INSTALL_IPA="$ROOT/dist/com.hejong2byte.simplecameraautosender.ipa"
LEGACY_IPA="$ROOT/dist/SimpleCameraAutoSender.ipa"
rm -f "$INSTALL_IPA" "$LEGACY_IPA"
ditto -c -k --sequesterRsrc --keepParent \
  "$BUILD_ROOT/Payload" \
  "$INSTALL_IPA"
cp "$INSTALL_IPA" "$LEGACY_IPA"

test -s "$INSTALL_IPA"
test -s "$LEGACY_IPA"
cmp "$INSTALL_IPA" "$LEGACY_IPA"
unzip -t "$INSTALL_IPA"
python3 "$ROOT/scripts/verify-ipa.py" "$INSTALL_IPA"
