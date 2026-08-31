#!/bin/bash
# Integration: every command the QML builds must be accepted by the real helper.
# Skips cleanly where qml6 or real accounts are unavailable.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
qml_runner=$(command -v qml6 || echo /usr/lib/qt6/bin/qml)
[ -x "$qml_runner" ] || { echo "Contract check SKIPPED (no qml6)"; exit 0; }

accounts=$(python3 "$root/onedrive-status.py" --list-accounts 2>/dev/null) || accounts=""
case "$accounts" in ''|'[]') echo "Contract check SKIPPED (no accounts discovered)"; exit 0 ;; esac

# Generated beside Contract.qml so its relative import of the widget resolves.
harness="$root/tests/qml/.Contract.generated.qml"
trap 'rm -f -- "$harness"' EXIT
python3 - "$root/tests/qml/Contract.qml" "$harness" "$accounts" <<'PY'
import json, sys
src = open(sys.argv[1]).read()
src = src.replace('property string discoveryJson: "[]"',
                  'property string discoveryJson: %s' % json.dumps(sys.argv[3]))
open(sys.argv[2], "w").write(src)
PY

commands=$( ( ulimit -c 0; QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  "$qml_runner" -I "$root/tests/qmlstubs" "$harness" 2>&1 ) | sed -n 's/^qml: CMD //p')
[ -n "$commands" ] || { echo "Contract check FAILED: the QML produced no commands" >&2; exit 1; }

count=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  mapfile -t argv < <(python3 -c 'import json,sys; [print(a) for a in json.loads(sys.argv[1])]' "$line")
  [ "${#argv[@]}" -gt 0 ] || continue
  case "${argv[*]}" in *--list-accounts*) continue ;; esac
  if ! out=$("${argv[@]}" 2>&1); then
    echo "Contract check FAILED: the helper rejected a command the widget builds" >&2
    printf '  argv:  %s\n  error: %s\n' "$line" "$out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True' 2>/dev/null; then
    echo "Contract check FAILED: helper output was not a valid status object" >&2
    printf '  argv: %s\n' "$line" >&2
    exit 1
  fi
  count=$((count + 1))
done <<<"$commands"

echo "Contract check passed ($count widget-built command(s) accepted by the real helper)"
