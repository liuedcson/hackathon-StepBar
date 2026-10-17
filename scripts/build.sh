#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/StepBar"
app_path="$PWD/build/StepBar.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/StepBar "$app_path/Contents/MacOS/StepBar"
/usr/bin/strip -S "$app_path/Contents/MacOS/StepBar"
mkdir -p "$app_path/Contents/Resources/browser-extension"
for file in manifest.json background.js options.html options.js; do cp "browser-extension/$file" "$app_path/Contents/Resources/browser-extension/$file"; done
cp scripts/install-update.sh "$app_path/Contents/Resources/install-update.sh"
cp scripts/uninstall.sh "$app_path/Contents/Resources/uninstall.sh"
# App icon: the StepFun mark, drawn by the app itself (Brand.swift).
iconset=$(mktemp -d)/AppIcon.iconset
.build/release/StepBar --make-icon "$iconset"
iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
mkdir -p browser-extension/icons
for size in 16 32 128; do cp "$iconset/icon_${size}x${size}.png" "browser-extension/icons/$size.png"; done
cp -R browser-extension/icons "$app_path/Contents/Resources/browser-extension/icons"
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
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>0.1.5</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>唤起 StepBar 后，长按 ⌥M 才录音，仅发送给你配置的语音转写服务。</string>
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
echo "Built: $app_path"
