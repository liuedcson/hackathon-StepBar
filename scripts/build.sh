#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app_path="$PWD/build/StepBar.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/StepBar "$app_path/Contents/MacOS/StepBar"
# App icon: the StepFun mark, drawn by the app itself (Brand.swift).
iconset=$(mktemp -d)/AppIcon.iconset
.build/release/StepBar --make-icon "$iconset"
iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
mkdir -p browser-extension/icons
for size in 16 32 128; do cp "$iconset/icon_${size}x${size}.png" "browser-extension/icons/$size.png"; done
rm -rf "${iconset:h}"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.stepbar.app</string>
<key>CFBundleName</key><string>StepBar</string>
<key>CFBundleDisplayName</key><string>StepBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Powered by StepFun 阶跃星辰 · Step Plan</string>
<key>CFBundleExecutable</key><string>StepBar</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>按住 ⌥ 说出要找的东西，录音只发给 StepFun 语音识别。</string>
</dict></plist>
PLIST
identity="StepBar Local Signing"
keychain="$HOME/Library/Keychains/stepbar-signing.keychain-db"
if [[ -f "$keychain" ]] && security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  security unlock-keychain -p stepbar-local-signing "$keychain"
  if ! security list-keychains -d user | grep -q "stepbar-signing"; then
    security list-keychains -d user -s ${(f)"$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')"} "$keychain"
  fi
  codesign --force --sign "$identity" "$app_path"
else
  echo "warning: '$identity' not found; ad-hoc signing resets Accessibility on every rebuild. Run ./scripts/setup-signing.sh" >&2
  codesign --force --sign - "$app_path"
fi
mkdir -p browser-extension
token=$(/usr/bin/plutil -extract bridgeToken raw -o - "$HOME/Library/Application Support/StepBar/settings.json" 2>/dev/null \
  || /usr/bin/plutil -extract bridgeToken raw -o - "$HOME/Library/Application Support/IntentBar/settings.json" 2>/dev/null || true)
if [[ -n "$token" ]]; then
  printf '{"token":"%s"}\n' "$token" > browser-extension/pairing.json
fi
echo "Built: $app_path"
