#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/StepBar.app/Contents/Info.plist)
arch=$(uname -m)
out="$PWD/build/release"
mkdir -p "$out"
asset="StepBar-${version}-${arch}.zip"
[[ ! -e build/StepBar.app/Contents/Resources/browser-extension/pairing.json ]] || { echo "构建产物含配对码，拒绝发布" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict build/StepBar.app
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr -c -k --keepParent build/StepBar.app "$out/$asset"
hash=$(/usr/bin/shasum -a 256 "$out/$asset" | cut -d ' ' -f1)
printf '{"version":"%s","asset":"%s","sha256":"%s","architecture":"%s"}\n' "$version" "$asset" "$hash" "$arch" > "$out/update-${arch}.json"
echo "Release assets ready: $out"
