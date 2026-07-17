# Backup & Eject

Backup & Eject is a small native macOS menu-bar app for deliberate, offline
Time Machine backups. It starts one manual backup to your chosen external
disk, shows live progress, waits for Time Machine to finish, safely ejects the
disk, and tells you when it can be powered off.

Keep your backup disk offline while you work. When you want a fresh recovery
point—especially before or after using AI tools with broad file access—connect
the disk, choose one menu command, and wait for confirmation that it is safe
to switch off.

## What it does

- Shows a first-run screen listing your configured local Time Machine disks.
- Remembers the exact Time Machine destination identity, not just its name.
- Offers **Back Up to [disk] & Eject** and a separate **Eject [disk]** command.
- Displays the current stage and any progress reported by macOS in a compact
  panel at the bottom-right of the desktop.
- Waits for Time Machine to become idle before asking macOS to eject the disk.
- Never force-ejects. If anything is uncertain, the disk stays connected and
  the app explains why.
- Can warn when ChatGPT, Claude, or Codex is still open.
- Has no analytics, advertising, accounts, or network service of its own.

## Requirements

- macOS 14 Sonoma or later.
- A directly attached external disk already configured in
  **System Settings → General → Time Machine**.
- Xcode Command Line Tools only if building from source.

Network Time Machine destinations are not supported because the app is
designed to eject a physical disk after the backup.

## Install

1. Download and unzip the latest macOS release.
2. Drag **Backup & Eject.app** into **Applications**.
3. Open it and choose your Time Machine disk on the first-run screen.

Until a Developer ID-notarized release is available, macOS may require you to
Control-click the app, choose **Open**, and confirm once. Moving the app into
Applications before enabling **Launch at Login** is recommended.

## Everyday use

1. Configure your external disk in Time Machine if you have not already.
2. Open Backup & Eject and choose that disk on the first-run screen.
3. Keep the backup disk disconnected or powered off while it is not needed.
4. Connect or power on the disk.
5. Choose **Back Up to [disk] & Eject** from the menu-bar icon.
6. Follow the small status panel.
7. Wait for the notification confirming that the disk is safe to switch off.

If you only need to disconnect the disk, choose **Eject [disk]**. The app first
checks that Time Machine is idle and then performs a normal macOS eject.

You can change the selected disk later with **Choose Backup Disk…**.

## Safety model

The selected Time Machine destination ID is stored locally in macOS user
defaults. Before every operation, the app asks `tmutil` for the configured
destinations and verifies that exact ID. If a different disk merely has the
same name, the app refuses to use it.

The backup is started with `tmutil`, monitored until completion, and followed
by a normal `diskutil eject`. No force-eject command is used.

Backup & Eject does not change Time Machine exclusions or decide which source
files macOS backs up. Review **Time Machine → Options** and verify your backups
periodically.

## Build and test

```sh
swift test
./scripts/build_app.sh
```

The app bundle is written to `dist/Backup & Eject.app`.

To make an ad-hoc-signed ZIP and SHA-256 checksum:

```sh
./scripts/package_release.sh
```

For the smoothest public download experience, release builds should eventually
be signed with an Apple Developer ID and notarized. An ad-hoc-signed build may
require the user to Control-click the app and choose **Open** the first time.

## Privacy

The app does not send data anywhere. Its only saved settings are the selected
destination name and ID, the AI-app warning preference, launch-at-login state,
and the date of the last successful backup for each selected disk.

## Support

If Backup & Eject saves you time or gives you peace of mind, you can
[buy me a coffee](https://buymeacoffee.com/aaronfish1labs).

## License and trademarks

Released under the [MIT License](LICENSE).

Time Machine and macOS are trademarks of Apple Inc. Backup & Eject is an
independent project and is not affiliated with or endorsed by Apple.
