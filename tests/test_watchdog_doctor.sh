#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# watchdog-doctor on fake machines: files under SF_ROOT, commands stubbed on PATH.
# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck source-path=SCRIPTDIR disable=SC2016
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
W=$HERE/bin/watchdog-doctor
R=$T/root
KVER=7.0.0-test

stub uname 'echo 7.0.0-test'
stub modinfo 'if [ "$*" = "-F alias sp5100_tco" ]; then echo "pci:v00001022d0000790Bsv*sd*bc*sc*i*"; fi'
stub systemctl 'if [ "$*" = "show -p RuntimeWatchdogUSec --value" ]; then echo "$RT"; fi'
stub sysctl 'case "$2" in
  kernel.panic) echo "$PANIC" ;;
  kernel.softlockup_panic) echo "$SOFT" ;;
  kernel.hardlockup_panic) echo "$HARD" ;;
  kernel.nmi_watchdog) echo "$NMI" ;;
  *) exit 1 ;;
esac'
stub systemd-analyze 'echo "[Journal]"; if [ -n "$SYNC" ]; then echo "SyncIntervalSec=$SYNC"; fi'

# A box with AMD's FCH watchdog timer (PCI 1022:790B): the driver is installed, not loaded.
machine() {
  rm -rf "$R"
  mkdir -p "$R/sys/class/watchdog" "$R/sys/bus/pci/devices/0000:00:14.0" "$R/sys/module" \
           "$R/lib/modules/$KVER/kernel/drivers/watchdog" "$R/lib/modprobe.d" "$R/etc/modules-load.d"
  echo "pci:v00001022d0000790Bsv0000F111sd00000006bc0Csc05i00" > "$R/sys/bus/pci/devices/0000:00:14.0/modalias"
  : > "$R/lib/modules/$KVER/kernel/drivers/watchdog/sp5100_tco.ko.zst"
  : > "$R/lib/modules/$KVER/kernel/drivers/watchdog/softdog.ko.zst"
  export SF_ROOT=$R RT=30s PANIC=10 SOFT=0 HARD=0 NMI=1 SYNC=""
}
watchdog() {  # watchdog0 in the given state
  mkdir -p "$R/sys/class/watchdog/watchdog0"
  echo "SP5100 TCO timer" > "$R/sys/class/watchdog/watchdog0/identity"
  echo "$1" > "$R/sys/class/watchdog/watchdog0/state"
  echo 30 > "$R/sys/class/watchdog/watchdog0/timeout"
}

machine
echo "blacklist sp5100_tco" > "$R/lib/modprobe.d/blacklist_linux_7.0.0.conf"
echo "sp5100_tco" > "$R/etc/modules-load.d/watchdog.conf"
run "$W"
expect "the trap: a blacklisted driver, and a load rule that does nothing" 1 \
  "FAIL +device +no watchdog device" \
  "FAIL +sp5100_tco +matches this hardware, but /lib/modprobe.d/blacklist_linux_7.0.0.conf blacklists it" \
  "FAIL +load rule +/etc/modules-load.d/watchdog.conf names sp5100_tco, and does nothing" \
  "ok +systemd +RuntimeWatchdogSec=30s" \
  "Verdict: this box would stay frozen" \
  "oneshot unit that runs 'modprobe sp5100_tco'"
refute "a driver for other hardware is not reported" "softdog"

machine
watchdog active
mkdir -p "$R/sys/module/sp5100_tco" "$R/sys/module/pstore/parameters"
echo efi_pstore > "$R/sys/module/pstore/parameters/backend"
export SOFT=1 HARD=1 SYNC=15s
run "$W"
expect "a fed watchdog, lockups that panic, pstore and a 15 s journal" 0 \
  "ok +watchdog0 +SP5100 TCO timer, active, times out after 30 s" \
  "ok +sp5100_tco +matches this hardware and is loaded" \
  "ok +panic logs +kept across a reboot by pstore \(efi_pstore\)" \
  "Verdict: a hang reboots this box by itself"
refute "nothing to fix" "To fix"

machine
run "$W"
expect "a driver that is not blacklisted, only not loaded" 1 \
  "warn +sp5100_tco +matches this hardware, but is not loaded" \
  "/etc/modules-load.d/sp5100_tco.conf"
refute "no load rule is blamed" "load rule"

machine
watchdog inactive
export RT=0
run "$W"
expect "a watchdog that nothing feeds" 1 \
  "warn +watchdog0 +SP5100 TCO timer, inactive: present, but nothing feeds it" \
  "FAIL +systemd +RuntimeWatchdogSec is not set: the watchdog is there"

machine
export PANIC=0
run "$W"
expect "kernel.panic=0 without a watchdog waits forever" 1 "FAIL +kernel.panic +0: after a panic the box waits forever"

machine
watchdog active
export PANIC=0
run "$W"
expect "kernel.panic=0 with a fed watchdog is only a warning" 0 "warn +kernel.panic +0: after a panic, only the watchdog reboots"

run "$W" --help
expect "--help explains itself" 0 "will this Linux box reboot itself when it hangs"
run "$W" --bogus
expect "an unknown argument is a usage error" 2 "usage: watchdog-doctor"
finish
