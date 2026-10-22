# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **All rsync options that work inside the sandbox**, as defaults in the new **Settings › rsync** tab and per job under **Advanced rsync options** in the New Job sheet: `--filter`/`--include`/`--exclude` (one pattern per line), `-F`, `--include-from`/`--exclude-from`/`--files-from`, `--max-size`/`--min-size`, `--ignore-existing`, `--existing`, `-u`, `-m`, `-H`, `-N`, `-U`, `--numeric-ids`, `-x`, `--chmod`, `-L`/`--copy-unsafe-links`/`--safe-links`, `--sparse`, `--inplace`, `-W`, `--append`/`--append-verify`, `--delete-before/after/delay`, `--delete-excluded`, `--max-delete`, `--ignore-errors`, `--size-only`, `--modify-window`, `--bwlimit`, `--stop-after`/`--stop-at`, `--iconv`, `--link-dest`/`--compare-dest`/`--copy-dest`, `-b`/`--backup-dir`/`--suffix`, `--info=progress1`, `--info=name1`, `--info=flist2`, `--info=stats2`, `-i`, `--no-inc-recursive`, `--log-file`, `--write-batch`/`--only-write-batch`. Invalid values are explained and block the job.
- The New Job sheet and the inspector show the exact `rsync …` command (shell-quoted, copyable).
- Job rows show the file being copied, per-file progress and a counter while the file list is built; statistics and change lines go to the job log.
- A job stopped by `--stop-at`/`--stop-after` is paused (resumable) and announced instead of failing.
- **Automatic snapshots** (per job): each run writes a dated folder (`yyyy-MM-dd-HHmmss`) in the destination, hard-links unchanged files to the previous snapshot (`--link-dest`), keeps an interrupted run as `….partial` and resumes it, points `Latest` at the newest snapshot, and applies optional retention rules (keep the last N, one per day, week or month) after a fully successful run only. Retention is confirmed when it is set; only folders whose names match the snapshot format exactly are ever removed.
- **Start when the destination disk is connected** (per job): the job waits while the disk is missing and runs (again) when it is mounted. A disk that is ejected or unplugged pauses the job using it; mounting it resumes the job.
- **Verify after copying** (off, quick or checksum; default in Settings › Copying): differences or an incomplete verification end the job as "not verified" and the differences are logged.
- **Preview** in the New Job sheet: a dry run listing what will be copied, updated and deleted, with deletions highlighted.
- **Edit and duplicate** existing jobs (Job menu and context menu); **run history** with result, duration, bytes, files and snapshot per run (last 100 runs).
- **Clear the queue:** a **Clear** toolbar menu (also in the Job menu and the job context menu) with "Remove Finished Jobs" and "Remove All Jobs…" (confirmed; a running job stays, copied files and snapshots are not touched).
- **Ready-made exclude lists:** developer, version control, caches and macOS helper files, in Settings › rsync and per job.
- **Menu bar icon** (progress, pause/resume all, open, quit; Copiator keeps running without a window while it is shown) and **Dock progress** with a badge for pending jobs; both can be turned off in Settings › General.
- **Shortcuts and Siri:** "Run Copy Job" (choose a job), "Pause All Jobs", "Resume All Jobs", with phrases in Turkish, English and Romanian. `Scripts/build_app.sh` generates the App Intents metadata with `appintentsmetadataprocessor`.
- **Sleep and power:** the sleep assertion (`caffeinate -i` equivalent) is verified in the system's assertion list; the app tells you when it is taken and released (start, finish, pause, cancel, quit) and shows a banner while a job runs. New option "Keep the display awake during a job" (`caffeinate -d` equivalent). Power advice for battery, low battery, Low Power Mode, the lid and the display, re-checked every minute during a job.

### Fixed

- **Crash when a job starts:** adding a job (for example the first one, from the New Job sheet) could terminate the app with "more Update Constraints in Window passes than there are views in the window". The sleep and power banner above the job list wrapped its text, so its height depended on the column width and the split view recomputed its layout in a loop. The banner above the list is now one line per item (full text in the tooltip); the inspector still shows it wrapped.
- **macOS's own rsync (limited mode) works again under the sandbox:** openrsync starts its receiving side as a separate `rsync` found through `PATH`; with another rsync earlier in `PATH` (e.g. Homebrew's) the sandbox refused it ("exec on 'rsync': Operation not permitted"). Copiator now passes `--rsync-path` with the engine's own path, does not ask openrsync to copy extended attributes (it writes temporary AppleDouble files to `/private/tmp` and breaks dry runs; the quarantine flag is still carried over and the dropped option is logged), and reads openrsync's 9-column `-i` output for verify, preview and the change log.
- **No orphaned rsync after a crash:** child processes are recorded; on a crash or termination signal Copiator stops them before exiting, and an rsync left running by a killed session (matched by process ID, exact start time and a dead parent) is stopped at the next launch and noted in the interrupted job's log.

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
