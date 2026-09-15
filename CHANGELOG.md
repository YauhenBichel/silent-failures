# Changelog

## 0.1.0 (unreleased)

The first tools, all from the same incident: a GPU server that froze for 8 hours while nobody was told.

- `watchdog-doctor`: will this box reboot itself when it hangs? It finds a watchdog driver that matches the
  hardware but is blacklisted, and a `modules-load.d` rule that silently does nothing.
- `last-boot`: did the previous boot end cleanly, and what was happening just before it ended?
- `timer-failures`: scheduled jobs whose last run failed, however healthy their timers look.
- `firmware-drift`: which upstream linux-firmware version the installed files really are, matched by hash.
- `gpu-mem-sampler`: GPU and system memory every few seconds, with a systemd user unit.
- `mac/reachability-watch.sh`: a macOS launchd watcher that notifies you when a server stays down, and again
  when it is back.
