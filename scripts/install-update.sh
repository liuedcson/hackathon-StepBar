#!/bin/zsh
# Called only after the app verifies the release checksum, bundle ID, version and signature.
set -u
pid="$1"
source_app="$2"
target="$3"
workspace="$4"
[[ "$target" == /*/StepBar.app && "$source_app" == "$workspace/StepBar.app" && "$workspace" == */stepbar-update-* ]] || exit 1
log="$HOME/Library/Application Support/StepBar/update.log"
mkdir -p "${log:h}" || exit 1
exec >>"$log" 2>&1
echo "$(date -u) Preparing update"
backup="${target}.update-backup-$$"
finished=0
restore() {
  if [[ "$finished" != 1 ]]; then
    echo "Update failed; restoring previous application"
    if [[ -e "$backup" ]]; then
      rm -rf "$target" || { echo "Cannot remove failed installation; backup retained"; return; }
      mv "$backup" "$target" || return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      [[ ! -d "$target" ]] || /usr/bin/open "$target"
    fi
    rm -rf "$workspace"
  fi
}
trap restore EXIT
trap 'exit 1' TERM INT HUP
touch "$workspace/helper-ready" || exit 1
for attempt in {1..60}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null || /bin/ps -axo comm= | /usr/bin/grep -Fxq "$target/Contents/MacOS/StepBar"; then
  echo "Application still running; update cancelled"
  exit 1
fi
[[ ! -e "$backup" ]] || exit 1
mv "$target" "$backup" || exit 1
if /usr/bin/ditto "$source_app" "$target" && /usr/bin/codesign --verify --deep --strict "$target"; then
  /usr/bin/open "$target" || exit 1
  finished=1
  echo "Update installed and launch requested"
  rm -rf "$backup" "$workspace"
else
  exit 1
fi
