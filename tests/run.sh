#!/bin/bash
# Usage: tests/run.sh [test files...]
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/assert.sh"
if [ $# -gt 0 ]; then files=("$@"); else files=("$HERE"/test_*.sh); fi
failed=0; total=0
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "no such test file: $f"; exit 1; }
  . "$f"
  for fn in $(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p'); do
    total=$((total + 1))
    log=$(mktemp "${TMPDIR:-/tmp}/capart-log.XXXXXX")
    (
      t_setup || exit 1
      trap 'rm -rf "$T"' EXIT
      case "$HOME" in "$T"/*) ;; *) echo "HOME not under test dir"; exit 1;; esac
      cd "$HOME" || exit 1
      "$fn"
    ) >"$log" 2>&1
    if [ $? -eq 0 ]; then echo "PASS $fn"; else echo "FAIL $fn"; sed 's/^/  | /' "$log"; failed=$((failed + 1)); fi
    rm -f "$log"
    unset -f "$fn"
  done
done
echo "$((total - failed))/$total passed"
[ "$failed" -eq 0 ]
