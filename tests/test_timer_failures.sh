#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# timer-failures against stubbed systemctl and journalctl.
# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck source-path=SCRIPTDIR disable=SC2016
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
TF=$HERE/bin/timer-failures
F=$T/systemd
mkdir -p "$F"
export UNITS=$F

# System timers: backup fails every night, clean succeeds, old failed before this boot and has not run
# since. One user timer, which succeeds.
printf '%s\n' "backup.timer loaded active waiting Nightly backup" "clean.timer loaded active waiting Clean" \
              "old.timer loaded active waiting Old job" "refresh.timer loaded active waiting Firmware refresh" > "$F/timers-system"
printf '%s\n' "mirror.timer loaded active waiting Mirror" > "$F/timers-user"
printf 'Result=exit-code\nExecMainStatus=2\nExecMainExitTimestamp=Tue 2026-09-15 07:15:36 UTC\n' > "$F/backup.service"
printf 'Result=success\nExecMainStatus=0\nExecMainExitTimestamp=Tue 2026-09-15 03:00:00 UTC\n' > "$F/clean.service"
printf 'Result=success\nExecMainStatus=0\nExecMainExitTimestamp=\n' > "$F/old.service"
printf 'Result=success\nExecMainStatus=0\nExecMainExitTimestamp=Tue 2026-09-15 05:00:00 UTC\n' > "$F/mirror.service"
# like fwupd-refresh: exit 2 is "nothing to do", and the unit says so with SuccessExitStatus=2
printf 'Result=success\nExecMainStatus=2\nExecMainExitTimestamp=Tue 2026-09-15 09:02:54 UTC\n' > "$F/refresh.service"
for day in 13 14; do
  echo "2026-09-${day}T03:15:02+00:00 box systemd[1]: backup.service: Failed with result 'exit-code'."
done > "$F/journal-backup.service"
echo "2026-09-15T07:15:36+00:00 box systemd[1]: backup.service: Failed with result 'exit-code'." >> "$F/journal-backup.service"
echo "2026-09-15T03:00:01+00:00 box systemd[1]: clean.service: Deactivated successfully." > "$F/journal-clean.service"
echo "2026-09-14T02:00:00+00:00 box systemd[1]: old.service: Failed with result 'exit-code'." > "$F/journal-old.service"

stub systemctl 'scope=system
if [ "$1" = --user ]; then scope=user; shift; fi
echo "$scope $*" >> "$UNITS/calls"
case "$1 $2" in
  "list-units --type=timer") cat "$UNITS/timers-$scope" ;;
  "show -p") echo "${5%.timer}.service" ;;
  show\ *) cat "$UNITS/$2" ;;
esac'
stub journalctl 'for a in "$@"; do case "$a" in *.service) cat "$UNITS/journal-$a" 2>/dev/null ;; esac; done'

run "$TF"
expect "a job that fails every night, and one that failed before this boot" 1 \
  "FAIL +system +backup.service +exit-code, exit 2, at Tue 2026-09-15 07:15:36 UTC; 3 failed run\(s\) in 7 days" \
  "FAIL +system +old.service +its last run failed before this boot, at 2026-09-14T02:00:00\+00:00; 1 failed run\(s\)" \
  "5 timer\(s\) checked, 2 failing"
refute "jobs that succeeded are not listed, even with an exit status the unit counts as success" \
  "clean.service|mirror.service|refresh.service"

run "$TF" --user
expect "user timers only" 0 "1 timer\(s\) checked, 0 failing"

rm -f "$F/calls"
run "$TF" --system --all
expect "--all lists the healthy jobs too" 1 "ok +system +clean.service +Tue 2026-09-15 03:00:00 UTC"
if ! grep -q "^user " "$F/calls"; then pass "--system never asks the user manager"; else failed "--system never asks the user manager" "$(cat "$F/calls")"; fi

run "$TF" --days 30
expect "--days sets the window for the count" 1 "failed run\(s\) in 30 days"
run "$TF" --days x
expect "--days needs a number" 2 "whole number"
finish
