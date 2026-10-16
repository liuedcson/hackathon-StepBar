#!/usr/bin/env python3
"""Explicit clean reinstall: keep source and config.local.json; never edit Chrome profiles."""
import pathlib, shutil, subprocess, os, signal, sys

root = pathlib.Path(__file__).resolve().parents[1]
home = pathlib.Path.home()
targets = [root / '.build', root / 'build', root / 'browser-extension/pairing.json',
           home / 'Library/Application Support/StepBar',
           home / 'Library/Preferences/local.stepbar.app.plist',
            home / 'Library/Caches/local.stepbar.app', home / 'Library/Saved Application State/local.stepbar.app.savedState']
extension = home / 'Downloads/StepBar-browser-extension'
# Only remove an export created by StepBar; leave unrelated folders and symlinks alone.
if not extension.is_symlink() and (extension / '.stepbar-managed').is_file():
    targets.append(extension)
for base in [pathlib.Path('/Applications'), home / 'Applications']:
    for name in ['StepBar.app']:
        app = base / name
        if app.exists():
            import plistlib
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') != 'local.stepbar.app':
                raise SystemExit('Application identity mismatch; refusing cleanup')
            targets.append(app)
if '--confirm' not in sys.argv:
    print('Dry run only. Add --confirm to remove these exact StepBar paths:')
    for path in targets:
        if path.exists(): print(path)
    raise SystemExit(0)
for row in subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines():
    fields = row.strip().split(None, 1)
    if len(fields) == 2 and fields[1].endswith('/StepBar.app/Contents/MacOS/StepBar'):
        os.kill(int(fields[0]), signal.SIGTERM)
subprocess.run(['osascript', '-e', 'delay 2'], check=True)
# Delete only credentials belonging to this app, including the legacy app service.
for service in ['local.stepbar.ai']:
    for _ in range(100):
        found = subprocess.run(['security', 'find-generic-password', '-s', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if found.returncode == 44: break  # errSecItemNotFound
        if found.returncode != 0: raise SystemExit('Cannot inspect app credentials; cleanup stopped')
        deleted = subprocess.run(['security', 'delete-generic-password', '-s', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if deleted.returncode != 0: raise SystemExit('Cannot remove app credential; cleanup stopped')
    else: raise SystemExit('Too many app credentials; cleanup stopped')
subprocess.run(['defaults', 'delete', 'local.stepbar.app'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['tccutil', 'reset', 'Microphone', 'local.stepbar.app'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for path in targets:
    if path.is_symlink() or path.is_file(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
print('StepBar local app, data, app credentials, managed extension export, pairing and builds removed. Source and config.local.json retained. Chrome profiles untouched. Remove the loaded StepBar extension manually at chrome://extensions.')
