#!/bin/zsh
# Called only after the app verifies the release checksum, bundle ID, version and signature.
set -eu
pid="$1"
source_app="$2"
target="$3"
workspace="$4"
[[ "$target" == */StepBar.app && "$source_app" == "$workspace/StepBar.app" ]] || exit 1
for attempt in {1..60}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill -0 "$pid" 2>/dev/null && exit 1
backup="${target}.update-backup"
[[ ! -e "$backup" ]] || exit 1
mv "$target" "$backup"
if /usr/bin/ditto "$source_app" "$target" && /usr/bin/codesign --verify --deep --strict "$target"; then
  /usr/bin/open "$target"
  rm -rf "$backup" "$workspace"
else
  rm -rf "$target"
  mv "$backup" "$target"
  /usr/bin/open "$target"
  exit 1
fi
