# Contributing

Thank you for helping. This repository collects small checks for failures that stay silent until the day you
need the thing that failed.

## What makes a good check

- It answers one question an engineer asks after an incident, such as "will this box reboot itself when it hangs?".
- It is read-only. It never changes the system; it prints the commands that would fix what it finds.
- It needs no root where it can, and says so clearly where it cannot.
- It comes from something that really failed. Say what, in the issue and at the top of the script.
- It has a test for every behaviour, and the tests run without root, network or the real hardware: put files
  under `SF_ROOT` and stubs for commands on `PATH` (see `tests/lib.sh`).

## Workflow

1. For a new tool, open an issue first, with the incident it comes from.
2. Make the change on a branch. Before you push, run:
   - `bash tests/run.sh` (Linux)
   - `shellcheck -x bin/watchdog-doctor bin/last-boot bin/timer-failures bin/gpu-mem-sampler mac/reachability-watch.sh tests/*.sh`
3. Open a pull request. CI runs the same checks on Linux and macOS.

Security problems: please report them privately, as [SECURITY.md](SECURITY.md) describes.
