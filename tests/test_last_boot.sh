#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# last-boot against a stubbed journal: one boot that froze, one that shut down cleanly.
# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck source-path=SCRIPTDIR disable=SC2016
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
L=$HERE/bin/last-boot
F=$T/journal
mkdir -p "$F" "$T/root/var/lib/systemd/pstore"
export SF_ROOT=$T/root JOURNAL=$F

cat > "$F/boots" <<'EOF'
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 8125d00f87cd47db961cbf8ce2aafa8e Sun 2026-09-13 11:38:34 UTC Sun 2026-09-13 22:39:31 UTC
 -1 c652dc6ee22a449db5a7f72b9befa34c Sun 2026-09-13 22:40:14 UTC Mon 2026-09-14 22:53:29 UTC
  0 56fe9d9036a5488aadd1fff3803dd462 Tue 2026-09-15 07:15:31 UTC Tue 2026-09-15 07:18:11 UTC
EOF
cat > "$F/tail-1" <<'EOF'
2026-09-14T22:53:23+00:00 box kernel: kauditd_printk_skb: 59 callbacks suppressed
2026-09-14T22:53:28+00:00 box kernel: audit: type=1400 apparmor="DENIED" operation="open"
2026-09-14T22:53:29+00:00 box sshd[2612801]: Accepted publickey for alice from 127.0.0.1
2026-09-14T22:53:29+00:00 box systemd-logind[1275]: Removed session 3100.
EOF
cat > "$F/kernel-1" <<'EOF'
2026-09-14T22:52:10+00:00 box kernel: amdgpu 0000:c5:00.0: ring gfx_0.0.0 timeout
2026-09-14T22:53:28+00:00 box kernel: audit: type=1400 apparmor="DENIED"
EOF
cat > "$F/tail-2" <<'EOF'
2026-09-13T22:39:31+00:00 box systemd-shutdown[1]: Syncing filesystems and block devices.
2026-09-13T22:39:31+00:00 box systemd-journald[549973]: Journal stopped
EOF
stub journalctl 'case "$*" in
  *--list-boots*) cat "$JOURNAL/boots" ;;
  *"-k -b -1 "*) cat "$JOURNAL/kernel-1" ;;
  *"-k -b "*) : ;;
  *"-b -1 "*) cat "$JOURNAL/tail-1" ;;
  *"-b -2 "*) cat "$JOURNAL/tail-2" ;;
esac'
stub hostname 'echo testbox'
stub notify-me 'printf "%s|%s\n" "$1" "$2" > "$JOURNAL/notified"'

run "$L"
expect "a boot that just stopped" 1 \
  "boot -1 \(c652dc6ee22a\), 2026-09-13 22:40:14 UTC to 2026-09-14 22:53:29 UTC" \
  "ended: +without a shutdown" \
  "next boot: 2026-09-15 07:15:31 UTC, 8h 22m 02s later" \
  "sshd\[2612801\]: Accepted publickey" \
  "ring gfx_0.0.0 timeout" \
  "saved panic logs \(/var/lib/systemd/pstore\):" \
  "^  none$"
refute "kernel audit noise is left out" "kauditd|audit: type"

run "$L" --boot -2
expect "a boot that shut down cleanly" 0 "ended: +with a shutdown or a reboot" \
  "next boot: 2026-09-13 22:40:14 UTC, 0h 00m 43s later" \
  "\(none left after removing audit noise\)"

run "$L" --notify notify-me
expect "--notify after an unclean end still reports it" 1
want="testbox: back after an unclean stop|Boot -1 ended at 2026-09-14 22:53:29 UTC without a shutdown; it was down 8h 22m 02s."
got=$(cat "$F/notified" 2>/dev/null)
if [ "$got" = "$want" ]; then pass "--notify gets a title and a summary"; else failed "--notify gets a title and a summary" "$got"; fi

rm -f "$F/notified"
run "$L" --boot -2 --notify notify-me
if [ ! -e "$F/notified" ]; then pass "--notify stays quiet after a clean end"; else failed "--notify stays quiet after a clean end"; fi

mkdir -p "$T/root/var/lib/systemd/pstore/1789426409"
: > "$T/root/var/lib/systemd/pstore/1789426409/dmesg-efi-178942640901"
: > "$T/root/var/lib/systemd/pstore/1789426409/dmesg.txt"
run "$L"
expect "saved panic logs are listed by crash, with the time" 1 "^  1789426409 \(2026-09-14 22:53:29 UTC\): 2 file\(s\)$"

run "$L" --boot -9
expect "a boot that is not in the journal" 2 "boot -9 is not in the journal"
run "$L" --boot 3
expect "a positive offset is a usage error" 2 "takes an offset"
finish
