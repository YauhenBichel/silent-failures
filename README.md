# silent-failures

[![CI](https://github.com/YauhenBichel/silent-failures/actions/workflows/ci.yml/badge.svg)](https://github.com/YauhenBichel/silent-failures/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

**Small checks for the failures that stay silent until the day you need the thing that failed.**

A hardware watchdog that never loads. A nightly job that fails every night. Firmware months behind upstream. A
server that froze, and nobody was told. Each tool here answers one question like that. It reads the system without
changing it, and prints what to fix.

## Why

Every tool comes from one real incident, on a home GPU server (AMD Ryzen AI Max+ 395):

- A GPU job started. 37 seconds later the machine froze, with nothing in the log. It stayed frozen for
  **8 hours 22 minutes**, until someone power-cycled it.
- systemd was set to feed a hardware watchdog, and a load rule for the watchdog driver sat in
  `/etc/modules-load.d`. There was still no watchdog: Ubuntu blacklists the driver (`sp5100_tco`), and systemd skips
  blacklisted modules without a word.
- The alerting ran on the machine that froze, so it froze too.
- The nightly system backup had failed every night for three days. The backup alert watched a different job's
  success stamp.
- The GPU firmware was three updates behind upstream, although the distribution package looked current.

Each of these would have shown up in a simple check. Nobody had run one.

| Tool | The question it answers |
|---|---|
| [`watchdog-doctor`](#watchdog-doctor) | Will this box reboot itself when it hangs? |
| [`last-boot`](#last-boot) | Did the previous boot end cleanly, and what was happening just before? |
| [`timer-failures`](#timer-failures) | Which scheduled jobs keep failing where nobody looks? |
| [`firmware-drift`](#firmware-drift) | Which upstream linux-firmware version am I really running? |
| [`gpu-mem-sampler`](#gpu-mem-sampler) | What were the GPU and the memory doing just before it went wrong? |
| [`mac/reachability-watch.sh`](#macreachability-watchsh) | When my server stays down, will I hear about it? |

## Install

```bash
git clone https://github.com/YauhenBichel/silent-failures
export PATH="$PWD/silent-failures/bin:$PATH"
```

- The Linux tools need `bash`, systemd and `journalctl`. None of them needs root. `last-boot` and `timer-failures`
  read the system journal, so run them as a member of the `systemd-journal` or `adm` group, or with `sudo`.
- `firmware-drift` needs Python 3.8 or newer, the `zstd` tool for `.zst` files, and network access to gitlab.com.
- `mac/reachability-watch.sh` runs on macOS, from launchd.

The exit codes mean the same thing in every tool: `0` all good, `1` something is wrong, `2` it could not tell (or
bad usage). So each one can run from a timer, from CI or from a monitoring agent.

## watchdog-doctor

**Will this box reboot itself when it hangs?**

This is the real output from the server that froze:

```console
$ watchdog-doctor
watchdog-doctor: will this box reboot itself when it hangs?

  FAIL  device           no watchdog device: nothing can reset this box when it hangs
  FAIL  sp5100_tco       matches this hardware, but /usr/lib/modprobe.d/blacklist_linux-hwe-7.0_7.0.0-31-generic.conf blacklists it: it never loads by itself
  FAIL  load rule        /etc/modules-load.d/watchdog.conf names sp5100_tco, and does nothing: systemd-modules-load skips blacklisted modules
  ok    systemd          RuntimeWatchdogSec=30s
  ok    kernel.panic     10: reboots 10 s after a panic
  warn  soft lockups     kernel.softlockup_panic=0: a soft lockup is only logged
  warn  hard lockups     kernel.hardlockup_panic=0: a hard lockup is only logged
  ok    panic logs       kept across a reboot by pstore (efi_pstore)
  warn  journal sync     default, every 5 min: the last minutes before a freeze are lost

Verdict: this box would stay frozen until someone power-cycles it.

To fix (printed, not run):
  - load sp5100_tco at boot from a oneshot unit that runs 'modprobe sp5100_tco': naming the module is not blocked by the blacklist (see the README)
  - kernel.softlockup_panic = 1 in /etc/sysctl.d/60-panic.conf
  - kernel.hardlockup_panic = 1 in /etc/sysctl.d/60-panic.conf
  - SyncIntervalSec=15s under [Journal] in /etc/systemd/journald.conf.d/60-sync.conf
```

What it checks:

- a watchdog device exists (`/sys/class/watchdog`), and something feeds it;
- which watchdog drivers match your hardware, and whether each one is loaded, blacklisted, or named in a load rule
  that cannot work;
- systemd's `RuntimeWatchdogSec`, which makes systemd feed the watchdog;
- `kernel.panic`, `kernel.softlockup_panic` and `kernel.hardlockup_panic`: whether a panic or a lockup ends in a
  reboot;
- a pstore backend, so the log of a panic survives the reboot;
- how often journald writes to disk, so the last seconds before a freeze are kept.

Exit 0: a hang reboots the box. Exit 1: it would stay frozen.

### Loading a blacklisted watchdog driver

A rule in `/etc/modules-load.d` does nothing for a blacklisted module. Naming the module does work: `sudo modprobe
sp5100_tco` loaded it on the same machine. So load it from a unit:

```ini
# /etc/systemd/system/watchdog-load.service
[Unit]
Description=Load the hardware watchdog driver
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/modprobe sp5100_tco

[Install]
WantedBy=sysinit.target
```

```bash
sudo modprobe sp5100_tco && ls /dev/watchdog0          # first check that the driver finds the timer
sudo systemctl daemon-reload && sudo systemctl enable watchdog-load.service
sudo mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=30s\n' | sudo tee /etc/systemd/system.conf.d/60-watchdog.conf
sudo systemctl daemon-reexec                             # systemd opens the watchdog and starts feeding it
watchdog-doctor                                          # the watchdog line should now say "active"
```

Use the driver `watchdog-doctor` names for your hardware instead of `sp5100_tco`.

## last-boot

**Did the previous boot end cleanly, and what was happening just before it ended?**

```console
$ last-boot
last-boot: boot -1 (c652dc6ee22a), 2026-09-13 22:40:14 UTC to 2026-09-14 22:53:29 UTC

  ended:     without a shutdown: the log just stops (a freeze, a crash or lost power)
  next boot: 2026-09-15 07:15:31 UTC, 8h 22m 02s later

last log lines (kernel audit noise removed):
  2026-09-14T22:53:29+00:00 server systemd-logind[1275]: New session 3100 of user alice.
  2026-09-14T22:53:29+00:00 server systemd[1]: session-3100.scope: Deactivated successfully.
  2026-09-14T22:53:29+00:00 server systemd-logind[1275]: Removed session 3100.

last kernel lines (audit noise removed):
  2026-09-14T20:13:23+00:00 server kernel: workqueue: kfd_process_wq_release [amdgpu] hogged CPU for >10000us 7 times, consider switching to WQ_UNBOUND
  2026-09-14T21:40:13+00:00 server kernel: workqueue: delayed_fput hogged CPU for >10000us 4 times, consider switching to WQ_UNBOUND

saved panic logs (/var/lib/systemd/pstore):
  1789045109 (2026-09-10 12:58:29 UTC): 17 file(s)
```

A clean end writes `systemd-shutdown` and `Journal stopped` into the journal. A freeze leaves neither: the log simply
stops. journald also warns "uncleanly shut down" at the next boot, but it does that after clean reboots too, so
`last-boot` does not use it. The saved panic logs in that example were from an earlier crash, days before, that
nothing else had recorded.

- `last-boot --boot -2` looks at an older boot.
- `last-boot --notify CMD` also runs `CMD "<title>" "<summary>"` when the end was unclean. Run it once at every boot
  (from a oneshot unit), and a freeze is reported as soon as the box is back. For example, with
  [ntfy](https://ntfy.sh):

  ```bash
  #!/bin/sh
  # notify-ntfy: last-boot passes a title and a summary
  curl -s -H "Title: $1" -d "$2" "https://ntfy.sh/$(cat /etc/ntfy-topic)"
  ```

Exit 0: a clean end. Exit 1: an unclean one. Exit 2: unknown.

## timer-failures

**Which scheduled jobs keep failing where nobody looks?**

```console
$ timer-failures
timer-failures: scheduled jobs whose last run failed (failures counted over 7 days)

  FAIL  system system-backup.service                exit-code, exit 2, at Tue 2026-09-15 07:15:36 UTC; 4 failed run(s) in 7 days

30 timer(s) checked, 1 failing.
```

A timer that fires on time looks healthy even when its job fails every night. For every systemd timer, system and
user, `timer-failures` reads the service the timer starts: the result of its last run, when that was, and how many
runs failed in the last N days. It also catches a job whose last run failed before the latest reboot and has not run
since. It trusts systemd's `Result`, not the raw exit status, because some units count a non-zero status as success
(`SuccessExitStatus=`).

Options: `--system`, `--user`, `--days N` (default 7), `--all` to list the healthy jobs too. Exit 0: nothing failing.
Exit 1: something is.

## firmware-drift

**Which upstream linux-firmware version am I really running?**

```console
$ firmware-drift --module amdgpu --match gc_11_5_1
file                        installed = upstream      newer upstream versions
amdgpu/gc_11_5_1_imu.bin    0599265ede5a 2024-12-03   none: current
amdgpu/gc_11_5_1_rlc.bin    5e35839d7b4c 2025-08-08   none: current
amdgpu/gc_11_5_1_mec.bin    dea4e8a3376c 2026-02-25   2, the newest 385ed4e463c2 2026-08-10
amdgpu/gc_11_5_1_me.bin     dea4e8a3376c 2026-02-25   2, the newest 385ed4e463c2 2026-08-10
amdgpu/gc_11_5_1_pfp.bin    dea4e8a3376c 2026-02-25   2, the newest 385ed4e463c2 2026-08-10
amdgpu/gc_11_5_1_mes1.bin   dea4e8a3376c 2026-02-25   1, the newest 385ed4e463c2 2026-08-10
amdgpu/gc_11_5_1_mes_2.bin  dea4e8a3376c 2026-02-25   3, the newest 617fe7d035e7 2026-09-11
```

On that machine the distribution package said version `20240318`. The files inside were from February 2026, and three
updates behind upstream. A package version cannot tell you that; a hash can.

For each file, `firmware-drift` finds the file the kernel would load, in the kernel's own order (`updates/` first,
uncompressed before `.zst` and `.xz`). It hashes the file's content, then walks that file's history in upstream
linux-firmware, newest first, until a version has the same SHA-256.

- Name files directly: `firmware-drift amdgpu/gc_11_5_1_mes_2.bin`, or give an installed path.
- `--module NAME` checks every file the module can load that is installed; `--match TEXT` narrows them.
- `--json` for scripts; `--depth N` versions per file (default 30). Upstream hashes are cached in
  `~/.cache/firmware-drift`.

Exit 0: all current. Exit 1: at least one file is behind. Exit 2: a file could not be matched (older than
`--depth` versions, changed locally, or not in upstream).

## gpu-mem-sampler

**What were the GPU and the memory doing just before it went wrong?**

```text
2026-09-14T22:53:32Z gtt=0.0 vram=20.7 avail=45.8 swap=4.0 top=python:9.6
2026-09-14T22:53:42Z gtt=0.0 vram=20.7 avail=46.1 swap=4.0 top=python:9.6
```

Those were the last two lines before the freeze: 13 seconds after the journal's last line, and more than any other
log on the box had. One line every 10 seconds: GPU memory in use (GTT and VRAM, in GiB, from amdgpu's sysfs; with
NVIDIA, VRAM from `nvidia-smi`), available memory, swap in use, and the process with the most resident memory.

```bash
gpu-mem-sampler --once                                     # one line, now
install -D -m 755 bin/gpu-mem-sampler ~/.local/bin/gpu-mem-sampler
install -D -m 644 systemd/gpu-mem-sampler.service ~/.config/systemd/user/gpu-mem-sampler.service
systemctl --user daemon-reload && systemctl --user enable --now gpu-mem-sampler
loginctl enable-linger "$USER"                             # keep it running while you are logged out
```

The log goes to `~/.local/state/gpu-mem-sampler/gpu-memory.log`, about 70 bytes a line. It is rotated at 20 MB, and
one old file is kept.

## mac/reachability-watch.sh

**When my server stays down, will I hear about it?**

The server's own alerting cannot tell you that it has frozen. A Mac on the same network can. Every 30 seconds this
tries `ssh`, and when that fails it tells "the server is off or hung" (no ARP answer) from "ssh is broken". After 5
minutes down you get a macOS notification, and another one when the server is back. Away from home (a different
router) nothing is counted, so a trip does not set it off.

```bash
mkdir -p ~/.config/reachability-watch
cat > ~/.config/reachability-watch/myserver.env <<'EOF'
SSH_HOST=myserver          # an ssh host that logs in without a password prompt
ADDRESS=192.168.1.10       # the server's LAN address
DOWN_NOTIFY_SECONDS=300
EOF
sed -e 's|NAME|myserver|g' -e "s|/path/to/silent-failures|$PWD/silent-failures|" silent-failures/mac/reachability-watch.plist \
  > ~/Library/LaunchAgents/com.github.silent-failures.reachability-watch.myserver.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.github.silent-failures.reachability-watch.myserver.plist
```

It logs only changes, to `~/Library/Logs/reachability-watch-myserver.log`:

```text
2026-09-14T22:54:06Z up -> ssh-down
2026-09-14T22:57:19Z ssh-down -> unreachable
2026-09-14T22:59:12Z notified: myserver is down: unreachable since 23:54
2026-09-15T07:16:00Z unreachable -> up
2026-09-15T07:16:00Z notified: myserver is back: It was unreachable for 8h 21m.
```

Log lines are in UTC; notifications show your local time. Run it from launchd, not from an IDE's terminal: macOS's
Local Network privacy blocks LAN traffic from processes some apps start, and there every LAN check fails.

## Tests

```bash
bash tests/run.sh                  # all of them, on Linux: no root, no network, no special hardware
shellcheck -x bin/watchdog-doctor bin/last-boot bin/timer-failures bin/gpu-mem-sampler mac/reachability-watch.sh tests/*.sh
```

The tests build fake machines: files under `SF_ROOT`, and stubs for `systemctl`, `journalctl`, `sysctl` and friends.
CI runs ShellCheck and every test on Linux, and the macOS parts on macOS.

## Contributing

New checks are welcome, especially ones born from something that really failed. Please read
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contributors

<!-- readme: contributors,bots/- -start -->
<p align="center">
  <a href="https://github.com/YauhenBichel" title="Yauhen Bichel" aria-label="Yauhen Bichel"><img src=".github/faces/YauhenBichel.svg" width="87" height="99" alt="Yauhen Bichel" /></a>
</p>
<!-- readme: contributors,bots/- -end -->

## License

Apache-2.0: [LICENSE](LICENSE).

## Disclaimer

The tools read the system and print suggestions; they never change anything. Check a suggestion before you run it:
a watchdog or a panic setting that does not suit your machine can reboot it. No warranty. This is not a medical,
legal or safety-certified product.
