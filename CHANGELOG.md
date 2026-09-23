# Changelog

## 1.1.2

- Stops timed-out system-command output collection at a firm deadline instead
  of waiting indefinitely for inherited pipes to close.
- Gives destination and status checks shorter limits and retries one transient
  stall before failing safely.
- Distinguishes a backup that never started from one that failed later, and
  explains that a powered disk can vanish when its USB data link or hub resets.
- Reduces destination polling while a selected disk is unavailable and keeps
  the no-eject-on-uncertainty rule.
- Adds regression tests for bounded output collection, destination and status
  retries, persistent stalls, and unexpected loss of disk access.

## 1.1.1

- Lets other apps cover the backup progress panel after it first appears.
- Prevents live progress updates from repeatedly bringing the panel forward.
- Adds regression tests for the panel's normal window level and repeated
  presentation behaviour.

## 1.1.0

- Waits for an automatic backup already running to the selected disk, then
  performs one verified blocking backup before safe ejection.
- Keeps `tmutil` standard error separate from plist/status parser input.
- Adds cancellation, including a safe `tmutil stopbackup` request during an
  active backup, and allows Quit to cancel before ejection begins.
- Adds 30-second limits to quick `tmutil` and `diskutil` commands and extends
  the post-backup idle wait to three minutes.
- Verifies the previous mount path before reporting a disk already unmounted.
- Builds a universal Apple silicon and Intel app.
- Updates Gatekeeper and AI desktop-app documentation.
- Adds automated command-runner and workflow regression tests.

## 1.0.1

- Adds a one-time in-app reminder that Backup & Eject follows the exclusions
  already configured in Time Machine.
- Offers a direct button to open Time Machine Settings before relying on a
  backup.

## 1.0.0

- First public version.
- First-run selection of an exact local Time Machine destination.
- One-command backup, completion monitoring, safe ejection, and notification.
- Separate safe-eject command.
- Compact bottom-right progress panel.
- Optional warning when common AI desktop apps are open.
