# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# Shared by the bash tests: source it first, call finish last.
#   stub NAME BODY                an executable NAME first on PATH, whose bash body is BODY
#   run CMD...                    sets $out (stdout and stderr together) and $code
#   expect NAME CODE [REGEX...]   the last run exited CODE, and its output matches every REGEX
#   refute NAME REGEX             the last run's output does not match REGEX
# shellcheck shell=bash disable=SC2034
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH"
n=0 fails=0 out="" code=0

pass()   { n=$((n + 1)); echo "ok   $1"; }
failed() {
  n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/     | /'; fi
}
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
run()  { out=$("$@" 2>&1); code=$?; }
expect() {
  local name=$1 want=$2 re
  shift 2
  if [ "$code" != "$want" ]; then failed "$name (exit $code, wanted $want)" "$out"; return; fi
  for re in "$@"; do
    if ! grep -qE -- "$re" <<< "$out"; then failed "$name (no match: $re)" "$out"; return; fi
  done
  pass "$name"
}
refute() { if grep -qE -- "$2" <<< "$out"; then failed "$1 (matched: $2)" "$out"; else pass "$1"; fi; }
finish() { echo "$((n - fails))/$n passed"; [ "$fails" = 0 ]; }
