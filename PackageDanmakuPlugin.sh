#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 - "$ROOT" "${1:-$ROOT/IINA-ANI/iina-plugin-danmaku.iinaplgz}" <<'PY'
import json
from pathlib import Path
import re
import sys
import tempfile
import zipfile

root = Path(sys.argv[1])
source = root / 'Plugins/Danmaku'
output = Path(sys.argv[2]).expanduser().resolve()
helper = root / 'IINA-ANI/WebFiles/Danmaku/danmaku-settings.js'
info = json.loads((source / 'Info.json').read_text())
lock = json.loads((source / 'package-lock.json').read_text())
app = (root / 'IINA-ANI/Features/Playback/IINAApp.swift').read_text()
if re.search(r'internalPluginVersion = "([^"]+)"', app).group(1) != info['version'] or int(re.search(r'internalPluginBuild = (\d+)', app).group(1)) != info['ghVersion']:
    raise SystemExit('Plugin Info.json and IINAApp.swift versions must match.')

entries = {}
for name in ('LICENSE', 'Info.json', 'main.js', 'global.js', 'pref.html',
             'package.json', 'package-lock.json', 'README.md', 'README.zh_CN.md',
             'Ytdl-Option-Loading-and-IINA-Open-Flow-zh-en.md'):
    entries[name] = source / name
for path in (source / 'DanmakuWeb').rglob('*'):
    if path.is_file() and not any(part.startswith('.') for part in path.relative_to(source).parts):
        entries[path.relative_to(source).as_posix()] = path
# One implementation shared with the App's browser renderer, never a forked copy.
entries['DanmakuWeb/danmaku-settings.js'] = helper
for name in ('comment-core-library', 'iina-plugin-definition'):
    dependency = source / 'vendor' / name
    package = json.loads((dependency / 'package.json').read_text())
    if package['version'] != lock['packages']['vendor/' + name]['version']:
        raise SystemExit('Vendored dependency version does not match package-lock.json: ' + name)
    for path in dependency.rglob('*'):
        if path.is_file() and not any(part.startswith('.') for part in path.relative_to(dependency).parts):
            entries['node_modules/' + name + '/' + path.relative_to(dependency).as_posix()] = path

output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.danmaku-', suffix='.zip', delete=False) as temporary:
    temporary_path = Path(temporary.name)
try:
    with zipfile.ZipFile(temporary_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in sorted(entries.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, path.read_bytes(), compresslevel=9)
    temporary_path.chmod(0o644)
    if not output.is_file() or output.read_bytes() != temporary_path.read_bytes():
        temporary_path.replace(output)
finally:
    temporary_path.unlink(missing_ok=True)
print(f"Packaged Danmaku {info['version']} (build {info['ghVersion']}): {output}")
PY
