# Security

These tools read system state: sysfs, `/proc`, systemd, the journal and module configuration. `firmware-drift`
also downloads file histories from the gitlab.com mirror of linux-firmware, and `mac/reachability-watch.sh` runs
`ssh` to a host you configure. None of them changes the system; the fixes they suggest are printed, never run.

## Reporting a problem

Please report vulnerabilities privately through GitHub's "Report a vulnerability" button on the Security tab of
this repository, rather than in a public issue. You can expect an acknowledgement within a week.

## What counts

- A way to make a tool change the system, or run a command you did not configure.
- A crafted file, journal entry or server response that makes a tool run code, or write outside its own cache
  and log.
- `firmware-drift` reporting a match for a file whose content differs from upstream.

## Not in scope

A wrong verdict on hardware or a configuration the tests do not cover. Please open an ordinary issue for that.
