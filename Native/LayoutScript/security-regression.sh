#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-script-security.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
bash "$ROOT/Native/LayoutScript/build.sh" "$TEMP_DIR/LayoutScriptHelper"
bash "$ROOT/Native/LayoutScript/build-probes.sh" "$TEMP_DIR/LayoutScriptSandboxProbes" > "$TEMP_DIR/probes.log"
# Exercise the helper with hardened-runtime ad-hoc signatures, not only unsigned binaries.
/usr/bin/codesign --force --options runtime --sign - "$TEMP_DIR/LayoutScriptHelper"
/usr/bin/codesign --force --options runtime --sign - "$TEMP_DIR/LayoutScriptSandboxProbes"
python3 - "$TEMP_DIR/LayoutScriptHelper" "$TEMP_DIR/LayoutScriptSandboxProbes" <<'PY'
import json, subprocess, sys, time
helper, probes = sys.argv[1:]
p = subprocess.run([probes], capture_output=True, text=True, timeout=5)
assert p.returncode == 0, (p.returncode, p.stderr)
assert set(p.stdout.splitlines()) == {
    'denied: file-read', 'denied: file-write', 'denied: network',
    'denied: fork', 'denied: exec', 'denied: keychain-mach'
}, p.stdout
print(p.stdout, end='')
def run(source, expected=0, raw=None):
    request = raw if raw is not None else json.dumps({'source':source,'context':{}}, ensure_ascii=False).encode()
    start = time.monotonic()
    p = subprocess.run([helper], input=request, capture_output=True, timeout=5)
    elapsed = time.monotonic() - start
    assert p.returncode == expected, (expected, p.returncode, p.stderr.decode(errors='replace'))
    return p, elapsed
p, _ = run('function buildLayout(c) { let a=[]; for(let i=0;i<3;i++) a.push(i*i); return {values:a}; }')
assert json.loads(p.stdout) == {'values':[0,1,4]}
p, elapsed = run('function buildLayout(c) { while(true){} }', 6)
assert b'wall-clock limit' in p.stderr and elapsed < 4
print('infinite loop: deadline exit 6')
p, elapsed = run('function buildLayout(c) { const a=[]; while(true) a.push(new Array(100000).fill(42)); }', 4)
assert b'physical-memory limit' in p.stderr and elapsed < 2
print('allocation loop: memory exit 4 before deadline')
run('function buildLayout(c) { return {get x(){while(true){}}}; }', 6)
p, _ = run('function buildLayout(c) {\nthrow new Error("located");\n}', 3)
assert b'layout.js:2' in p.stderr and b'located' in p.stderr
run('function buildLayout(c) { return "x".repeat(1048575); }', 7)
p, _ = run('function buildLayout(c) { return "x".repeat(1048574); }')
assert len(p.stdout) == 1048576
run('function buildLayout(c) { return "文".repeat(349525); }', 7)
p, _ = run('function buildLayout(c) { return "文".repeat(349524); }')
assert len(p.stdout) == 1048574
run(' ' * 131073, 2)
run('', 2, b'x' * 262145)
p, _ = run('function buildLayout(c) { return [typeof fetch,typeof require,typeof process,typeof ObjC]; }')
assert json.loads(p.stdout) == ['undefined'] * 4
print('hardened ad-hoc helper: JSON execution, serialization deadline, error location, UTF-8 output and input limits passed')
PY
