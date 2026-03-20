#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SkyPaste"
BUNDLE_ID="com.huaibor.skypaste"
APP_VERSION="$(cat "$ROOT_DIR/VERSION")"
APP_STORE_BUILD="${APP_STORE_BUILD:-0}"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/PasteNowClone.app"
ICON_PNG="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
ENTITLEMENTS_FILE="$ROOT_DIR/SkyPaste.entitlements"

cd "$ROOT_DIR"

swift_build_args=(build -c release)
if [[ "$APP_STORE_BUILD" == "1" ]]; then
  swift_build_args+=(-Xswiftc -DAPP_STORE_BUILD)
fi
swift "${swift_build_args[@]}"

mkdir -p "$ICONSET_DIR"
swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$ICON_PNG"

for icon_spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size="${icon_spec%% *}"
  name="${icon_spec#* }"
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/$name" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/SkyPaste" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

find "$ROOT_DIR/.build" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -print0 | while IFS= read -r -d '' resource_bundle; do
  cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign_args=(codesign --force --deep --sign -)
if [[ -f "$ENTITLEMENTS_FILE" ]]; then
  codesign_args+=(--entitlements "$ENTITLEMENTS_FILE")
fi
"${codesign_args[@]}" "$APP_DIR"

echo "Built app: $APP_DIR"
