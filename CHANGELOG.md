# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **All rsync options that work inside the sandbox**, as defaults in the new **Settings › rsync** tab and per job under **Advanced rsync options** in the New Job sheet: `--filter`/`--include`/`--exclude` (one pattern per line), `-F`, `--include-from`/`--exclude-from`/`--files-from`, `--max-size`/`--min-size`, `--ignore-existing`, `--existing`, `-u`, `-m`, `-H`, `-N`, `-U`, `--numeric-ids`, `-x`, `--chmod`, `-L`/`--copy-unsafe-links`/`--safe-links`, `--sparse`, `--inplace`, `-W`, `--append`/`--append-verify`, `--delete-before/after/delay`, `--delete-excluded`, `--max-delete`, `--ignore-errors`, `--size-only`, `--modify-window`, `--bwlimit`, `--stop-after`/`--stop-at`, `--iconv`, `--link-dest`/`--compare-dest`/`--copy-dest`, `-b`/`--backup-dir`/`--suffix`, `--info=progress1`, `--info=name1`, `--info=flist2`, `--info=stats2`, `-i`, `--no-inc-recursive`, `--log-file`, `--write-batch`/`--only-write-batch`. Invalid values are explained and block the job.
- The New Job sheet and the inspector show the exact `rsync …` command (shell-quoted, copyable).
- Job rows show the file being copied, per-file progress and a counter while the file list is built; statistics and change lines go to the job log.
- A job stopped by `--stop-at`/`--stop-after` is paused (resumable) and announced instead of failing.
- **Sleep and power:** the sleep assertion (`caffeinate -i` equivalent) is verified in the system's assertion list; the app tells you when it is taken and released (start, finish, pause, cancel, quit) and shows a banner while a job runs. New option "Keep the display awake during a job" (`caffeinate -d` equivalent). Power advice for battery, low battery, Low Power Mode, the lid and the display, re-checked every minute during a job.

### Security

- Extra sandbox permissions are granted per job only for paths you choose: list files (read), log and batch files (write that file), an outside old-versions folder and the `--link-dest` previous backup (write). Paths inside the source are refused. List files in protected folders are read by the app and passed to rsync as a private temporary copy, so the protected folder stays closed.

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
