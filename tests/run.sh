#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# Every test, on Linux, with no root and no network:  bash tests/run.sh
set -u
cd "$(dirname "$0")/.." || exit 2
status=0
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
echo "== tests/test_*.py"
python3 -m unittest discover -s tests -p 'test_*.py' || status=1
exit "$status"
