# Copiator

A native backup and sync app for macOS 26+, built with SwiftUI and Liquid Glass on top of [rsync](https://rsync.samba.org). It is built as a universal app (Apple Silicon + Intel), and a dependency-free universal rsync 3.5.1 ships inside the app bundle.

Copiator copies from a local disk to a local disk (internal, external, USB or network-mounted volumes). The job model and the engine layer are engine-independent, so other engines can be added as new job kinds.

## Features

- **Job queue** (like Transmission): every job has a source, a destination, options, a status (waiting, waiting for disk, scanning, copying, verifying, paused, finished, failed), progress, speed, time left and a log. Jobs run one at a time in list order; drag to reorder.
- **Resume:** an interrupted job continues with the same command (`--partial`); only what is missing is copied. Pausing, quitting the app or a full disk never loses work.
- **Honest progress:** bytes copied, percentage, speed, time left and checked items come from rsync's `--info=progress2`. While rsync is still scanning (`ir-chk`), the row says the estimate is not final.
- **Verify:** runs the same job as a dry run (`-n -i`, optionally with checksums `-c`) and lists missing, changed and extra items. Nothing is changed. Jobs can also **verify automatically after copying** (quick or checksum); differences fail the job and are written to its log.
- **Preview before adding:** the New Job sheet can dry-run the job and list what will be copied, updated and — when `--delete` is on — deleted, highlighted in red.
- **Automatic snapshots:** every run writes a dated folder (`yyyy-MM-dd-HHmmss`) in the destination; unchanged files are hard-linked to the previous snapshot (`--link-dest`, no extra space), `Latest` points to the newest, an interrupted snapshot is resumed, and optional retention rules (keep the last N, one per day/week/month) delete expired snapshots only after a successful run.
- **Start when the destination disk is connected:** the job waits (instead of failing) while the disk is missing and starts when it is plugged in, even if it already finished. Ejecting a disk pauses the job using it; reconnecting resumes it.
- **Copy routines:** a library in the sidebar of named, reusable routines with Finder-style rules. Each route copies the files in a source folder that match its rules to a destination, keeping the folder structure; add routes to send different files to different places. Conditions on name, extension, any folder name in the path, relative path (contains, is, begins with, ends with, regular expression) and file kind (image, movie, audio, PDF, document, spreadsheet, presentation, text, source code, archive, application), combined with All / Any / None and nested groups. Advanced criteria: size, date modified/created/added, Finder tags, visibility (hidden files), folder depth, an extension list ("jpg, heic, png"), date taken, resolution, duration and camera model of photos and videos, and text inside files (Spotlight). Rules are evaluated on every run; a "Try" field shows which routes a sample path matches, and each route has a preview. Routines can be run from the sidebar, the menu bar and Shortcuts.
- **Files with the same name:** before copying, Copiator lists every file that already exists at the destination under the same name (even with identical contents) and asks what to do: **1 · Replace**, **2 · Keep Both** (the new file is copied as `report 2.xlsx`, Finder-style) or **3 · Skip**, for all files at once or file by file, optionally remembered for the job or routine. A folder arriving where a file of the same name exists (or a file where a folder or link exists) is asked about too, instead of rsync silently deleting what is there; Keep Both then renames the existing item. If nobody is around (e.g. a routine started by connecting a disk), the job waits as "Needs decision", a notification arrives and the next jobs continue. Jobs and routines can also be set to replace, keep both or skip without asking.
- **Edit and duplicate jobs** without losing their history; every run is recorded in the job's **history** (result, duration, bytes, files, snapshot).
- **Ready-made exclude lists:** developer folders (`node_modules`, `DerivedData`, `.build`, `Pods`, Python and JavaScript caches), version control (`.git`, `.svn`, `.hg`), caches (`Library/Caches`, `.cache`) and macOS helper files (`.DS_Store`, `._*`, Trash).
- **Menu bar and Dock:** a menu bar icon with the running job's progress and pause/resume all (Copiator keeps running without a window while it is on), and a progress bar and pending-job badge on the Dock icon.
- **Shortcuts and Siri:** "Run Copy Job", "Run Copy Routine", "Pause All Jobs" and "Resume All Jobs" actions, e.g. "Run Photos in Copiator".
- **No orphaned rsync:** if Copiator crashes or is terminated, the running rsync is stopped; one left over from a killed session is stopped at the next launch.
- **Copy mode:** "copy the folder itself" (`Source` → `Destination/Source/…`) or "copy its contents" (`Source/` → `Destination/…`), with a preview of the result.
- **Every rsync option that works in the sandbox:** filters and list files, size limits, hard links, creation/access times, symlink handling, sparse/in-place/append writes, deletion details, size-only comparison, time tolerance, bandwidth limit, stop after/at a time, file-name encoding, a manually chosen previous backup (`--link-dest`, `--compare-dest`, `--copy-dest`), old versions (`--backup-dir`), per-file or exact progress, current file name, statistics, change log, log and batch files. Defaults in **Settings › rsync**, per job in the New Job sheet; the exact `rsync …` command is shown before it runs. See [docs/rsync-possible-in-sandbox.md](docs/rsync-possible-in-sandbox.md) and [docs/rsync-not-possible-in-sandbox.md](docs/rsync-not-possible-in-sandbox.md).
- **Safe by default:**
  - the source is never modified (`--remove-source-files` is never used; the sandbox makes the source read-only even inside the destination);
  - deleting extra files at the destination (`--delete`) only when chosen per job and confirmed;
  - rsync runs in a `sandbox-exec` sandbox with networking off, writes only to the destination and cannot read personal folders (`~/.ssh`, Keychains, browser profiles…) unless you choose them as the source;
  - jobs whose source and destination overlap are refused;
  - free space is checked before copying and watched while copying.
- **exFAT/FAT disks:** permissions, owners and ACLs are not sent to disks that cannot store them; harmless "failed to set times / permissions" warnings become one info line; FAT gets `--modify-window=1` so re-runs do not recopy everything.
- **macOS details:** system folders (`.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`…) are left out; the quarantine flag of downloaded files is kept even when extended attributes are not copied; a notification arrives when a job finishes.
- **Sleep and power:** while a job runs the Mac does not idle-sleep (the same assertion as `caffeinate -i`, optionally `-d` for the display). Copiator checks the assertion in the system's own list (what `pmset -g assertions` shows), tells you when it is taken and released (start, finish, pause, cancel), and advises about battery, Low Power Mode, the lid and the display; the power state is re-checked every minute during a job.
- **Finder:** right-click › **Back Up with Copiator**, or drop a folder on the window.
- **Languages:** Turkish (default), English, Romanian. **Appearance:** Automatic, Light, Dark.
- **rsync updater:** downloads the latest release from [github.com/RsyncProject/rsync](https://github.com/RsyncProject/rsync/releases), verifies its SHA-256 and builds it on your Mac (needs the Xcode Command Line Tools).

## Installation

**Requires:** macOS 26 (Tahoe) or later. Runs on Apple Silicon and Intel Macs.

1. Download the latest `Copiator-<version>.dmg` from the [Releases](https://github.com/berkbb/copiator-mac-universal/releases) page.
2. Optionally verify the download in the folder you downloaded it to:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```
3. Open the `.dmg` and drag **Copiator** into the **Applications** folder.
4. **First launch:** Copiator is ad-hoc signed rather than signed with an Apple Developer ID, so macOS shows a warning the first time. Go to **System Settings › Privacy & Security**, click **Open Anyway** next to "Copiator was blocked", and confirm.
5. On first launch, Copiator asks for permission to check GitHub for updates. You can change this later in **Settings › Advanced**.

**Finder context menu:** "Back Up with Copiator" appears under right-click › **Quick Actions** or **Services**. If it is missing, enable it in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.

## Development

Double-click in Finder:

- **`Paketle.command`** (package): runs the tests and produces a universal `build/Copiator.app` plus a `.dmg`, an Ed25519 signature (`.dmg.sig`) and `SHA256SUMS.txt` under `dist/`.
- **`rsync-Guncelle.command`** (update rsync): updates `Vendor/rsync` and, if present, the rsync inside `build/Copiator.app`.
- **`Yayimla.command`** (publish): shows a dry run first; if you confirm, packages the release and uploads it to GitHub Releases. GitHub Actions is not used.

The same tasks from the terminal:

```bash
./Scripts/build-rsync.sh              # build Vendor/rsync from the v3.5.1 tag (universal, /usr/lib only)
./Scripts/update-rsync.sh check       # is a newer rsync available?
./Scripts/update-rsync.sh install     # download, verify, build and install into Vendor/rsync
./Scripts/build_app.sh                # build/Copiator.app only
./Scripts/package.sh                  # tests + .app + .dmg + .dmg.sig + SHA256SUMS.txt
./Scripts/set-version.sh 1.0.1        # change the version (single source: Support/Info.plist)
./Scripts/release.sh --dry-run        # rehearse a release without sending anything
./Scripts/stress-test.sh              # pre-release stress round
swift test                            # unit, integration (real rsync), chaos/security matrix, fuzz and UI-render tests
```

Requires Xcode 26 or later. See [DEVELOPMENT.md](DEVELOPMENT.md) for the architecture, [roadmap.md](.agents/context/roadmap.md) for planned features and [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

Copiator is free software under the GNU General Public License, version 3 or later ([LICENSE](LICENSE)); © Babadogan Tech and Edu. The bundled rsync is GPL-3.0-or-later as well and is run as a separate, unmodified program; its exact source, build flags and checksum are in [Vendor/rsync/SOURCE.txt](Vendor/rsync/SOURCE.txt). Some components are derived from an MIT-licensed project; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
