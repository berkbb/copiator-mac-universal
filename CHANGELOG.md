# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-10-21

First release: local disk to local disk backup and sync with rsync.

### Added

- **Job queue** in the style of Transmission: source, destination, options, status (waiting, scanning, copying, paused, finished, failed), progress bar, bytes copied, speed, time left, checked items and a per-job log. Jobs run one at a time in list order, can be reordered, paused, resumed, run again and removed; the whole queue can be held. Sidebar filters with counts and a detail inspector.
- **Resume:** an interrupted, paused or failed job continues with the same rsync command (`--partial`). Jobs are saved to `~/Library/Application Support/Copiator/jobs.json`; after a quit or crash during a copy the job comes back paused and marked as interrupted (optionally resumed at launch).
- **Verify:** dry run of the job (`-n -i`, optionally with checksums `-c`) listing missing, changed, extra and attribute-only differences; nothing is written.
- **Copy mode:** copy the folder itself or its contents, with a preview of where the copy lands.
- **Options:** keep permissions, owner and ACLs (`-pogA`); keep extended attributes (`-X`); leave out macOS system folders (`.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`, …); delete extra files at the destination (`--delete`, only when chosen and confirmed). Defaults for new jobs in Settings › Copying.
- **exFAT/FAT/NTFS destinations:** no permission flags, harmless attribute warnings shown as one line, `--modify-window=1` on FAT.
- **Bundled rsync 3.5.1**, universal and linked only to macOS system libraries, built from the official `v3.5.1` tag by `Scripts/build-rsync.sh`; source, commit, flags and SHA-256 in `Vendor/rsync/SOURCE.txt`.
- **Engine selection** between the bundled rsync, an updated copy, Homebrew, a custom rsync and (last resort, limited progress) macOS's own rsync.
- **rsync updater** (`Scripts/update-rsync.sh`, "Check for rsync Updates…", `rsync-Guncelle.command`): GitHub release check, SHA-256 verified source download, local universal build, Mach-O and version checks, atomic install, fallback folder when the app bundle is read-only.
- Idle sleep is prevented while a job runs; a notification arrives when a job finishes or fails.
- Finder service "Back Up with Copiator" and drag and drop onto the window.
- Turkish (default), English and Romanian, 1:1; Automatic, Light and Dark appearance; customizable shortcuts.
- About window with Copiator License, rsync License and Third-Party Notices shown read-only inside the app.
- Copiator update check through GitHub Releases (asked for on first launch), Ed25519-signed DMGs and SHA-256 checksums.

### Security

- rsync runs under `sandbox-exec`: no network, writes only to the destination, sources read-only even inside the destination, no other programs or mach services, personal-data folders (`~/.ssh`, Keychains, browser profiles, …) unreadable unless chosen as the source and excluded from larger sources. Verify runs without any writable folder.
- The source is never modified: `--remove-source-files` is never produced, and jobs whose source and destination overlap are refused.
- Free space is checked before copying and watched while copying; the copy stops before the destination fills up.
- The quarantine flag of downloaded files is carried to copies even when extended attributes are not copied.
- Error classes are recognized only at rsync's message position or errno text, so file names cannot fake an error class.
