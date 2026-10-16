#!/bin/zsh
# Installed beside StepBar's local memory; no Python or source checkout required.
set -euo pipefail
data="$HOME/Library/Application Support/StepBar"
app=""
if [[ -f "$data/app-location.txt" ]]; then
  app=$(cat "$data/app-location.txt")
fi
if [[ -z "$app" || "$app" != /* || "$app" != *.app || -L "$app" ]]; then
  echo "无法确认 StepBar 安装位置，未执行卸载。"
  exit 1
fi
if [[ -d "$app" ]]; then
  identity=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
  [[ "$identity" == "local.stepbar.app" ]] || { echo "应用身份不匹配，未执行卸载。"; exit 1; }
fi
printf '卸载 StepBar 并删除本机记忆、设置与密钥？输入 YES 确认：'
read -r answer
[[ "$answer" == "YES" ]] || { echo "已取消。"; exit 0; }
while read -r pid executable; do
  if [[ "$executable" == "$app/Contents/MacOS/StepBar" ]]; then
    /bin/kill -TERM "$pid"
  fi
done < <(/bin/ps -axo pid=,comm=)
/bin/sleep 2
if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$app/Contents/MacOS/StepBar"; then
  echo "StepBar 尚未退出，请从菜单栏退出后重试。"
  exit 1
fi
while true; do
  code=0
  /usr/bin/security find-generic-password -s local.stepbar.ai >/dev/null 2>&1 || code=$?
  [[ "$code" -eq 44 ]] && break
  [[ "$code" -eq 0 ]] || { echo "无法访问 StepBar 钥匙串，清理已停止。"; exit 1; }
  /usr/bin/security delete-generic-password -s local.stepbar.ai >/dev/null
done
/usr/bin/defaults delete local.stepbar.app >/dev/null 2>&1 || true
/usr/bin/tccutil reset Microphone local.stepbar.app >/dev/null 2>&1 || true
extension="$HOME/Downloads/StepBar-browser-extension"
if [[ ! -L "$extension" && -f "$extension/.stepbar-managed" ]]; then
  /bin/rm -rf "$extension"
fi
/bin/rm -rf "$app" \
  "$HOME/Library/Caches/local.stepbar.app" \
  "$HOME/Library/Preferences/local.stepbar.app.plist" \
  "$HOME/Library/Saved Application State/local.stepbar.app.savedState"
# Delete the directory containing this script last.
/bin/rm -rf "$data"
echo "StepBar 已卸载。请到 chrome://extensions 手动移除 StepBar 扩展。"
