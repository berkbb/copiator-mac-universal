# Development

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6.2+). The universal build needs full Xcode; the Command Line Tools are not enough.
- To rebuild rsync from its git tag: `autoconf` (`brew install autoconf`). Building from a release tarball (what the in-app updater does) needs only the Command Line Tools.

## Folder layout

```
Copiator/
├── Package.swift
├── Sources/
│   ├── CopiatorCore/              UI-independent, tested logic (no SwiftUI)
│   │   ├── CommandRunner.swift      Process execution, \r/\n record streaming, timeout, cancel (SIGTERM → 2 s → SIGKILL), output cap
│   │   ├── Sandbox.swift            sandbox-exec profile per transfer (destination writable, sources read-only, personal folders hidden)
│   │   ├── RsyncCommand.swift       Every rsync argument (transfer, verify), file-system aware flags, filters, display string
│   │   ├── AdvancedOptions.swift    All sandbox-compatible rsync options per job, validation, extra sandbox paths
│   │   ├── RsyncOutputCollector.swift  Classifies output records: progress, names, file-list counter, changes, statistics
│   │   ├── PowerAdvisor.swift       PowerSnapshot (AC/battery/Low Power Mode), PowerAdvisor rules, SleepGuard (verified assertions)
│   │   ├── RsyncProgress.swift      TransferProgress + --info=progress2 parser
│   │   ├── RsyncOutcome.swift       Exit code + stderr → JobResult (harmless FAT/exFAT warnings, full/read-only/permission…)
│   │   ├── ItemizeParser.swift      `-i` output → DiffEntry (missing, changed, attributes, extra)
│   │   ├── Engine.swift             EngineLocator (candidates, version parsing, choosing), EngineUpdater (update-rsync.sh)
│   │   ├── TransferEngine.swift     Engine-independent protocol, events, EngineContext, VerifyReport, engine registry
│   │   ├── RsyncEngine.swift        The rsync implementation: preflight, sandbox, disk guard, progress throttle, quarantine
│   │   ├── Job.swift                TransferJob, CopyOptions, JobStatus, JobResult, JobLogEntry, JobValidation (Codable, backward compatible)
│   │   ├── JobStore.swift           jobs.json persistence (atomic, corrupt files set aside) and JobQueue rules (incl. waiting for a disk)
│   │   ├── Snapshots.swift          SnapshotOptions, SnapshotStore (dated folders, .partial resume, Latest link, retention, pruning)
│   │   ├── ChildProcessGuard.swift  Signal-safe child registry, crash/termination handlers, orphan reaping at launch
│   │   ├── Rules.swift              RuleGroup/RuleCondition (Finder-style rules: attributes, operators, units), FileKind
│   │   ├── RuleEvaluation.swift     RuleItem (lazy metadata), MediaInfo (ImageIO/AVFoundation), RuleEvaluator, RuleScanner, Spotlight
│   │   ├── Routines.swift           Routine, RoutineRoute, RoutineStore (routines.json), RuleSelection (--files-from list or placement staging)
│   │   ├── Placement.swift          RoutePlacement (folder and name templates, tokens), PlacementStaging (link tree), PlacementDate
│   │   ├── ContentReader.swift      ContentReader (PDFKit and plain text), TextDate (dates in names and text)
│   │   ├── ArchiveTools.swift       DestinationIndex (same contents at the destination), DestinationSummary, FolderSuggester
│   │   ├── Conflicts.swift          ConflictPolicy/Decision/Resolution/Report, ConflictDetector (-ii parsing, numbered names)
│   │   ├── DiskSpace.swift          DiskSpace, DiskSpaceGuard, FileSystemKind, OwnerAccess, saturating Int64
│   │   ├── Quarantine.swift         Keeps com.apple.quarantine when xattrs are not copied
│   │   ├── SleepAssertion.swift     IOPMAssertion (system or display type; caffeinate -i / -d equivalents)
│   │   ├── OpenSafety.swift         Visible rendering of deceptive characters in paths
│   │   ├── AppUpdate.swift          GitHub release check, Ed25519 signature and SHA-256 verification
│   │   └── Localization.swift       AppLanguage, StringTable, LKey (all string keys)
│   └── Copiator/                  SwiftUI app (default isolation: MainActor)
│       ├── CopiatorApp.swift        Scenes, menu commands, AppDelegate
│       ├── AppModel.swift           Engine probing, queue execution, pause/resume, verify, updates, persistence
│       ├── AppSettings.swift        UserDefaults preferences, shortcuts, localization and formatting
│       ├── FinderServices.swift     "Back Up with Copiator" service
│       ├── Intents.swift            App Intents: JobEntity, Run Copy Job, Pause/Resume All Jobs, AppShortcutsProvider (Siri phrases)
│       ├── StatusItems.swift        Menu bar window, Dock tile progress and badge, NSWorkspace mount/unmount watcher
│       └── Views/                   ContentView (overlay, toast), job list, inspector and history, routines (rule editor,
│                                    routine editor and detail), New/Edit Job with snapshots,
│                                    automation and preview, Verify, Settings, About, license viewer
├── Resources/                     {tr,en,ro}.lproj/{Localizable,InfoPlist,ServicesMenu,AppShortcuts}.strings, AppIcon.icns
├── Support/Info.plist             Bundle info, NSServices, repository and update key
├── Scripts/                       build-rsync.sh, update-rsync.sh, build_app.sh, package.sh, release.sh, set-version.sh,
│                                  verify_bundle.sh, stress-test.sh, StressProbe.swift, make_icon.swift, update_signing.swift
├── Vendor/rsync/                  The rsync bundled into the app: rsync, COPYING, NEWS.md, SOURCE.txt
├── Tests/CopiatorCoreTests/       Unit, live-rsync integration, sandbox, fuzz and (opt-in) stress tests
├── Tests/CopiatorAppTests/        AppModel flows with real rsync, settings, overlay timing, off-screen view rendering
├── Paketle.command                Double-click to package
├── Yayimla.command                Double-click to publish to GitHub Releases
└── rsync-Guncelle.command         Double-click to update rsync
```

## Architecture

- **Process boundary:** Copiator never links rsync. It launches the unmodified `rsync` executable as a separate process (`CommandRunner`), which also keeps the GPL boundary simple.
- **Arguments:** `RsyncCommand` is the only place arguments are made. Default local copy: `-rltDhX --info=progress2 --partial`, macOS system folders excluded. Paths are absolute and come after `--` (names starting with `-` are not options; a name with `:` is not taken for a remote host because rsync only looks at a colon before the first `/`). "Copy its contents" adds a trailing `/` to the source. `--remove-source-files` is never produced (a `precondition` and tests guard this); `--delete` only when the job option is set, which the UI confirms.
  - "Keep permissions" adds `-pogA` (`-pog` when the engine has no ACL support).
  - exFAT, FAT and NTFS destinations (`FileSystemKind.lacksPosixMetadata`) never get `-p/-o/-g/-A`. FAT also gets `--modify-window=1` because it stores times in 2-second steps.
  - With extended attributes off, `-X` is dropped and `Quarantine.propagate` still copies `com.apple.quarantine` to the new items.
- **Progress:** `CommandRunner` streams stdout as records split on `\r` and `\n` and keeps only a 64 KB tail (`retainStdout: false`), so hours of progress lines never pile up. `RsyncProgressParser` reads `bytes pct rate eta (xfr#N, to-chk=a/b | ir-chk=a/b)`: bytes are 1000-based with `-h` (`29.70K`), rates 1024-based (`kB/s`), `??:??:??` means unknown. `ir-chk` sets `isEstimating`. `ProgressThrottle` sends at most four events a second.
- **Results:** `RsyncOutcome` maps exit codes (0, 20, 23, 24, 1/2/4, 3, 11/12/30/35…) and stderr to `JobResultKind`. Error classes are matched only at rsync's message position or as the trailing errno text, never anywhere in the line, so a file named `No space left on device (28).txt` or `chown notes.txt` cannot fake a class. On exFAT/FAT/NTFS, a 23 whose errors are all attribute warnings becomes `succeededWithNotes` with one info line.
- **Sandbox:** `SandboxProfile.forTransfer` allows writes only to the destination, then denies writes to the sources (SBPL: last match wins), so even `--delete` cannot touch a source inside the destination. Network, `mach-lookup` and `process-exec` (except rsync itself) are denied; local rsync forks and talks over a socketpair, which works under these rules. Personal-data folders are read-denied unless chosen as the source; when a source contains them (backing up the whole home folder), they are passed to rsync as anchored `--exclude` patterns instead of producing permission errors. Verify runs with no writable folder at all. Paths go through `realpath(3)` (`/private/var`).
- **Advanced options:** `CopyOptions.advanced` (`AdvancedOptions`) holds every rsync option that works inside the sandbox. All defaults produce no extra argument, so a default job runs exactly the original command. `AdvancedOptions.problems(source:)` validates patterns, `--chmod`, `--iconv`, suffixes, numbers, absolute paths and paths that would be written inside the source; the New Job sheet and `AppModel.addJob` refuse a job with problems, and the engine checks again. Filter order: sandbox-protected folders, system folders, then the user's `--filter`, `--include`, `--exclude`, `-F` and list files (first match wins, so a user include cannot re-include a protected folder). Verify passes only options that change the comparison (filters, `-H`, attribute flags, `--size-only`, `--modify-window`, reference directory, `--delete-excluded`). With openrsync, unsupported options are dropped and listed in the job log (`RsyncCommand.droppedOptions`). `RsyncCommand.displayString` shows the exact shell-quoted command in the New Job sheet and the inspector.
  - Extra sandbox paths per job: list files and the reference directory are readable; `--log-file` and `--write-batch` (file and `.sh`) are writable files; an outside `--backup-dir` and the `--link-dest` reference are writable folders. A hard link counts as a write to the existing file in macOS's sandbox (no narrower operation works), so `--link-dest` needs write access to the previous backup; `--compare-dest`/`--copy-dest` only read it.
  - rsync opens list files (`--files-from`, `--include-from`, `--exclude-from`) one path component at a time, so a list inside a protected folder cannot be read even with a file-level allow rule. `RsyncEngine.stageListFiles` copies the lists to a private 0700 temporary folder that is deleted after the run.
  - `--stop-at`/`--stop-after` make rsync print `stopping at requested limit` and exit 30; this becomes `JobResultKind.stoppedAtLimit`, the job is paused and resumable, and a stop time already in the past is ignored when resuming. `--preallocate` is not offered (this build reports "no prealloc"); `--read-batch` is a separate operation, not a copy option.
  - `RsyncOutputCollector` turns stdout records into model data: progress lines (per-file mode accumulates finished file sizes and takes the overall fraction from checked items), `--info=name1` names (current item), `flist2` counters (`isListing`, the job stays "scanning"), `-i` change lines (batched at most once a second, at most 500 per batch, delivered as one `TransferEvent.logBatch` so `jobs.json` is not written per file) and the `stats2` block (written to the log at the end).
- **Sleep and power:** `SleepGuard` takes a `PreventUserIdleSystemSleep` assertion (`caffeinate -i`) and, with "Keep the display awake", a `PreventUserIdleDisplaySleep` one (`caffeinate -d`). It verifies them in the system's per-process assertion list (`IOPMCopyAssertionsByProcess`, the source of `pmset -g assertions`) and checks they are gone after release. `AppModel` logs and announces the start (verified or not), the release (finish, pause, failure, quit) and power advice from `PowerAdvisor` (on battery, battery below 20 % / 10 %, Low Power Mode, lid, display), and re-reads the power state every 60 s during a job, announcing only new warnings and a reconnected adapter.
- **Snapshots:** with `CopyOptions.snapshots.enabled` the job's destination is a snapshot root. `SnapshotStore.prepare` reuses the newest `yyyy-MM-dd-HHmmss.partial` folder or creates one; `SnapshotStore.apply` points rsync at it and sets `--link-dest` to the newest complete snapshot (the user's own reference setting is ignored in this mode and `--delete` is not offered). The preflight counts the previous snapshot as already present. After a successful (or exit-23 partial, or not-verified) run the folder is renamed to a name that is always later than the newest existing one and `Latest` (a relative symlink, never replacing a real item) is moved atomically. Retention (`keepLast`, `keepDaily`, `keepWeekly`, `keepMonthly`; a snapshot stays if any rule keeps it, the newest always stays) runs only after a fully successful run and deletes only real folders whose names parse exactly as snapshot names; read-only folders in a snapshot are made writable inside that tree before removal. Verify and preview compare the source with the newest snapshot, or with an empty temporary folder before the first one.
- **Verify after copy:** `CopyOptions.verifyAfterCopy` (off, quick, checksum) runs `RsyncEngine.compare` inside the same run (status `verifying`, sleep assertion still held). Missing and changed items count as differences; extra items count only when `--delete` is on; attribute-only differences never count. Differences or an incomplete verification give `JobResultKind.verificationFailed` (the job fails, the first 100 differences are logged, a snapshot is still completed but no pruning happens).
- **Disks:** `VolumeWatcher` forwards `NSWorkspace` mount notifications to `AppModel`. A volume matches a job when the source or destination path is on its mount point (`/` never matches). `willUnmount`/`didUnmount` cancel the running job on that disk and mark it `suspendedForDisk` (also waiting jobs, and jobs that failed in the last 30 s, e.g. after a pulled cable); `didMount` requeues suspended jobs and re-runs finished or failed jobs that have `runWhenConnected`. `JobQueue.next` skips a waiting `runWhenConnected` job whose paths are missing instead of letting it fail.
- **Routines and rules:** a `Routine` has routes (source folder, `RuleGroup`, destination folder) and shared `CopyOptions`. Running it upserts one job per route (`TransferJob.routeID`): an idle job is updated and requeued, a waiting or running one is left alone, a missing one is created. `Routine.jobOptions(for:)` forces "copy contents", turns `--delete` off and puts the route's rules into `CopyOptions.rules`. At run time (and in verify/preview) `RsyncEngine.prepareRules` scans the source with `RuleScanner` (FileManager enumeration; packages count as one item; system folders and, under the sandbox, protected personal folders are not entered), evaluates `RuleEvaluator` (NFC-normalized names, case-insensitive text with Turkish I/ı/İ/i folded, regexes compiled once, any ancestor folder for "folder name", UTType conformance for kinds, depth limit 8; groups short-circuit). Advanced criteria read metadata lazily through `RuleItem`: size and dates from the enumeration attributes, "date added" and Finder tags from URL resource values, the hidden flag from `lstat` (`UF_HIDDEN`) or a leading dot, photo/video details prefetched by the scanner only when a media condition exists (ImageIO for images: pixel size, EXIF date, TIFF model; AVFoundation for audio/video: duration, video size, creation date, QuickTime model), and "contents" from one synchronous Spotlight `MDQuery` per condition scoped to the source (`kMDItemTextContent == "*text*"cd`). Spotlight folds case with the system locale (on a Turkish Mac the index holds "I" as "ı" and "İ" as "i"), so `Spotlight.query(for:)` searches every i-like letter as both "i" and "ı" (`||` of up to 64 variants; with more than six such letters, `&&` of the parts between them). Relative dates use the evaluator's `now` and calendar (the amount is clamped to 1,000,000 units so huge numbers cannot trap), so tests are deterministic. Regex conditions run with `.reportProgress`: ICU calls the block per start position and every few thousand backtracking steps (a count, not a clock), and after `RuleEvaluator.regexStepBudget` (5,000) calls the match stops, `runawayPattern` is set and `RuleScanner` throws `RuleEvaluator.RunawayRegex`; the engine logs `logRuleRegexTooComplex` and fails the job. Generated lists go to `EngineContext.scratchDirectory` (the user's temporary folder in the app; tests pass their own folder). The scanner then writes the matching relative paths to a private 0700 temp list passed as `--files-from` (NUL-separated with `--from0`; newline-separated for openrsync or when another `*-from` file is set, skipping names with line breaks). rsync then keeps the structure (`--files-from` implies `--relative`). The preflight counts only the selected files. The list is reused by verify-after-copy and deleted after the run.
- **Placement (route templates):** `RoutineRoute.placement` (`RoutePlacement`: folder template, keep structure, name template, date source, month-name language) becomes `CopyOptions.placement`. `RuleSelection.prepare` then builds a staging tree in the job's private scratch folder instead of a `--files-from` list (`PlacementStaging.build`): every selected file becomes an absolute symbolic link at its target path (`RoutePlacement.target`), with the source's extended attributes copied onto the link (rsync reads attributes from the link itself); packages are mirrored (real folders, file links, relative links that stay inside the package recreated, escaping links and selected symbolic links skipped and logged as `logPlacementLinksSkipped`); folders that exist in the source get its times. The job's source becomes the staging root and symlinks become `--copy-unsafe-links` (unless the user chose `-L`), so the conflict check, Keep Both (`singleFile` now carries the symlink flags), verification, quarantine propagation and resume run unchanged on target paths; the sandbox profile also gets the real source as a read-only source (`RsyncEngine.readSources`), and the preflight sums the real source files and the target counterparts. Template values pass `RoutePlacement.component` (no "/", ":" or control characters, leading dots and spaces trimmed until stable, 240 bytes); a staged path with "." or ".." is skipped. Dates: `PlacementDate.resolve` (date taken via `MediaInfo`, `TextDate.find` on the name or `ContentReader.text`, file dates).
- **Content and destination criteria:** "text inside files" unions Spotlight's result with `ContentReader` (PDFKit for PDFs up to 50 pages, the first 1 MB of plain text in UTF-8 or Windows-1254; case, diacritics and Turkish I/ı/İ/i ignored) through `RuleItem.textContent`. "Copy with the same contents at the destination" (`RuleAttribute.inDestination`) builds a `DestinationIndex` of the job's destination only when a rule uses it: files grouped by size, SHA-256 compared only for same-size candidates and cached.
- **Routine on selected items:** `AppModel.runRoutine(_:on:)` groups the items by folder and queues one job per (folder, route) with `CopyOptions.selectedItems` (the scanner only looks at those top-level names), `routineID` set and no `routeID`, so the routine's own jobs are untouched. Entry points: the `sendToRoutine` Finder service (`RoutinePickerSheet`), `RunRoutineOnFilesIntent` and drops on sidebar routine rows.
- **Destination overview and folder suggestions:** `DestinationSummary.compute` (volume capacity, counts, size per first-level folder and the top five extensions; hidden files skipped) and `FolderSuggester` (Ratcliff/Obershelp similarity, Turkish folding, abbreviation and containment bonuses, content bonus, sibling enrichment; folders listed without hidden folders or package contents, at most 20,000).
- **Same-name files (conflicts):** `CopyOptions.conflictPolicy` (ask, replace, keepBoth, skip; default ask) and the one-time `TransferJob.conflictResolution` (per-path decisions plus a decision for "others"). Unless the policy is replace, `RsyncEngine.planConflicts` runs `RsyncCommand.conflictCheck` (`-n -ii`, without reference-directory options so `--link-dest` files do not look present) and `ConflictDetector` turns every existing file line into a `FileConflict` (identical when nothing would be transferred). A line rsync shows as new (`>f+++`, `cd+++`, `cL+++`) is also a conflict when `ConflictCollector` finds something of another type at that destination path with `lstat` (parent folders must be real folders; links are never followed): rsync would delete it silently. These carry `incomingFolder` for a folder; Keep Both renames the existing item to the next numbered name before the transfer (a failed rename excludes the folder instead). Only undecided conflicts are reported; `AppModel.resolveConflicts` merges the sheet's decisions into the earlier ones. Undecided conflicts emit `TransferEvent.conflicts` (at most 5,000 listed) and end the run with `JobResultKind.awaitingDecision` (the job pauses; the app shows `ConflictSheet` and notifies). Decided skip/keep-both paths go to a private `--exclude-from` list anchored at the transfer root (`RsyncCommand.escapePattern("/" + path)`: rsync treats a pattern as a wildcard pattern only when it contains `*`, `?` or `[`, and only then is `\` an escape, so the whole pattern is escaped once and only in that case; NUL-separated with `--from0`, which must precede the list options because rsync reads an exclude file when it parses the option); keep-both files are copied afterwards one by one with `RsyncCommand.singleFile` to `ConflictDetector.numberedName` ("name 2.ext", the next free number). `TransferEvent.conflictsSettled` marks the pass so a resumed run treats new same-name files (its own partial copies) as replace. Snapshots, `--ignore-existing` and `--only-write-batch` skip the check.
- **History:** `JobQueue.finish` appends a `JobRun` (start, finish, result with snapshot name and difference count, bytes, files) to `TransferJob.history`, capped at 100 runs.
- **Orphan guard:** `CommandRunner` registers every child with `ChildProcessGuard` (a fixed table readable from a signal handler, plus `running-processes.json` in the app). The app installs handlers for crash and termination signals that send SIGTERM to registered children and re-raise the signal. SIGKILL cannot be caught, so `AppModel.launch` first stops recorded processes whose start time matches exactly and whose parent is launchd, and logs it in the interrupted job.
- **Menu bar, Dock, Shortcuts:** `MenuBarExtra` (window style) shows the running job and pause/resume all; while it is shown the app does not quit when its last window closes. `DockProgress` draws a progress bar on the Dock tile and a badge with running and waiting jobs, redrawing only when the shown values change. App Intents live in the app target; SwiftPM emits the compiler's constant values (`*.swiftconstvalues`) and `Scripts/build_app.sh` turns them into `Contents/Resources/Metadata.appintents` with `xcrun appintentsmetadataprocessor` (Xcode does this step itself; SwiftPM does not). Titles are `Localizable.strings` keys; Siri phrases are in `AppShortcuts.strings`. `verify_bundle.sh` checks the actions and phrases are in the metadata.
- **Engine layer:** a job carries a `JobKind`; `TransferEngines.engine(for:)` returns the `TransferEngine` (today only `RsyncEngine`). Another engine is added as a new kind; queue, persistence and UI stay the same.
- **Queue:** `AppModel` runs one job at a time: the first `waiting` job in list order. Events travel through an `AsyncStream` and are applied in order on the main actor; the result is written only after all events. A started job switches to `scanning` immediately. Pause cancels the task (rsync gets SIGTERM, keeps the partial file, exits 20) and the job becomes `paused`; resume requeues it with the same command. While a job runs, an `IOPMAssertion` prevents idle sleep.
- **Persistence:** `JobStore` writes `~/Library/Application Support/Copiator/jobs.json` atomically. Decoding is tolerant (missing fields get defaults; unknown kinds, statuses or result kinds fall back). An unreadable file is renamed to `jobs.corrupt-<time>.json` and reported. On quit the running job is stopped and saved as interrupted; at launch it comes back paused (or waiting with "Resume interrupted jobs at launch").
- **Disk space:** before copying, the source size minus the matching data already at the destination must fit, leaving a reserve of 1 GB (at most 2 % of the volume, so small USB sticks stay usable). While copying, `DiskSpaceGuard` stops rsync when free space drops below 512 MB (half the reserve for small volumes); the job can be resumed after freeing space.
- **Engine selection:** candidates are the custom rsync (Settings), the bundled one, `~/Library/Application Support/Copiator/engine`, Homebrew and `/usr/bin/rsync`. A working custom rsync always wins; otherwise the newest full rsync wins, and macOS's openrsync (no `--info=progress2`, no `-X`/ACLs) is used only as a last resort in a limited mode.
  - openrsync starts its receiving side with `execvp("rsync")` even for local copies, so it gets `--rsync-path=<its own resolved path>` (`RsyncCommand.rsyncPathFlags`): the receiver is the same binary and the only program the sandbox lets it run.
  - It is never asked to copy extended attributes: `--extended-attributes` makes it write temporary AppleDouble files as `/private/tmp/.<pid>.<name>` and breaks dry runs. `Quarantine.propagate` still carries the quarantine flag; `-X` is listed in the job log as a dropped option.
  - Its `-i` codes are 9 columns wide and `*deleting` is not padded; `ItemizeParser.Format(engine:)` picks the right layout for verify, preview and the change log.

## Bundled rsync

`Scripts/build-rsync.sh` clones `RsyncProject/rsync` at `v3.5.1`, builds arm64 and x86_64 separately with `--disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn --with-included-popt` (ACL, xattr and iconv on), joins them with `lipo -create`, checks with `otool -L` that only `/usr/lib` libraries are used, ad-hoc signs it and writes `Vendor/rsync/SOURCE.txt`.

- The git tag has no generated `configure.sh`; the script recreates `aclocal.m4` from rsync's own `m4/*.m4` (rsync does not use automake) and runs `autoconf`/`autoheader`. `.git` is removed before building so the version reads `3.5.1`, as in release tarballs.
- x86_64 is cross-configured (`--host=x86_64-apple-darwin`) with the arm64 run's cached test results, because macOS 27 may have no Rosetta to run x86_64 test programs.
- The binary built from the git tag and the one built from the release tarball are byte-identical (same SHA-256).

## rsync update flow

`update-rsync.sh` picks its target like the app expects:

| Run from | Updated |
| --- | --- |
| The project (`Scripts/`) | `Vendor/rsync/` |
| Inside the app (`Copiator.app/Contents/Resources/`) | That app's `Contents/MacOS/rsync`; the bundle is then ad-hoc re-signed |
| The app bundle is not writable | `~/Library/Application Support/Copiator/engine/` |
| `--dest` / `--app` given | The given targets |

Steps: GitHub release check (`RsyncProject/rsync`, drafts and pre-releases ignored) → download `rsync-X.Y.Z.tar.gz` → compare with GitHub's SHA-256 digest → `build-rsync.sh --tarball` → Mach-O and `--version` check → copy under a temporary name, then move into place. Without the Command Line Tools it stops with `ERROR=command-line-tools-missing`, which the app shows as a clear message.

## Adding strings (localization)

1. Add the key to `LKey` in `Sources/CopiatorCore/Localization.swift`.
2. Add it to **all three** dedicated files: `Resources/{tr,en,ro}.lproj/Localizable.strings`.
3. Format specifiers must match across languages; use positional ones (`%1$@`) when the order can differ.

`swift test` catches missing or extra keys, mismatched specifiers, English left in the Turkish or Romanian table, hard-coded text in views and icon-only buttons without an accessibility label.

## Build, test, package

```bash
swift build
swift test                                   # all suites; real-rsync tests use Vendor/rsync/rsync (or $COPIATOR_RSYNC)
COPIATOR_VOLUME_TESTS=1 swift test           # also copy to real FAT32 and exFAT disk images (hdiutil)
COPIATOR_STRESS_FILES=20000 swift test --filter StressTests
COPIATOR_SNAPSHOT_DIR=/tmp/copiator-ui swift test --filter ViewRenderTests   # PNGs of the main screens
./Scripts/build_app.sh                       # universal build/Copiator.app (ARCHS=native for this Mac only)
./Scripts/package.sh                         # tests + .app + dist/Copiator-<version>.dmg (+ .sig, SHA256SUMS.txt)
```

### Chaos and security matrix

`Tests/CopiatorCoreTests/ChaosAndSecurityMatrixTests.swift` (29 cases) and `Tests/CopiatorAppTests/ChaosAndLoadAppTests.swift` (3) run in every `swift test`. Disciplines: security (a decoy engine compiled with `xcrun clang` logs every call and tries to write outside the destination: blocked for the conflict check, transfer and numbered copies, and verification cannot even write the destination; unsandboxed, the same decoy escapes, which checks the test itself), stress (3,000-file routine, 5,200 same-name files), destructive (unreadable source file, vanished listed file, Finder-locked destination file), penetration (planted links, linked destination folder, quarantine on numbered copies), load (change lines, progress flood, 100 queued jobs), volume (huge rule numbers, video sizes, an 8 EiB sparse source refused before copying), endurance (20 runs: no temporary files, no open descriptors in the workspace, no overwritten numbered copies), vulnerability (runaway regex, option-like names), red team (wildcard and backslash names, items of another type, destination inside the source, placement templates that try to leave the destination), fuzz (dry-run output, rule algebra, damaged routine files, placement templates and text dates; seeded SplitMix64) and chaos (cancel during the conflict check with an engine that ignores SIGTERM, new conflicts after a decision, parallel runs, relaunch while awaiting a decision, decisions across two sheets). Each guarantee was verified by removing it and watching its test fail.

### Pre-release stress round

```bash
./Scripts/stress-test.sh                 # core round + real app round
./Scripts/stress-test.sh --skip-app      # core round only (no accessibility permission needed)
./Scripts/stress-test.sh --files 50000
```

- Core round: a 20,000-file tree plus a 1 GB file is copied, cancelled, resumed and verified (source unchanged, progress throttled, cancel under 5 s), and copies to real FAT32 and exFAT disk images re-run cleanly.
- App round: seeds one job into the app's queue, launches the app and drives it through accessibility with language-independent identifiers (`copiator.job`, `copiator.job.toggle`, `copiator.progress`, `copiator.progress.cancel`, `copiator.joblist`), never sending keystrokes. Checks: the job starts by itself, pause and resume work, all files arrive, the quarantine flag is kept, the source is unchanged, the worst UI response stays under 1500 ms, VoiceOver finds a name for every control, and no crash report appears. The queue and the settings it changes are restored on exit.
- The app that runs the script needs the Accessibility permission (System Settings › Privacy & Security › Accessibility).

## Publishing a release (locally)

1. `./Scripts/set-version.sh 1.0.1` (version and build number in `Support/Info.plist`).
2. In `CHANGELOG.md`, add `## [1.0.1] — <date>` below `## [Unreleased]`.
3. Commit and push; then `./Scripts/release.sh --dry-run` and `./Scripts/release.sh`.

`package.sh` signs the `.dmg` with the Ed25519 key in the login keychain (`com.babadogantech.copiator.update-signing`; the public key is `CopiatorUpdatePublicEDKey` in Info.plist; a backup lives in the git-ignored `.secrets/`). The repository's single source is `CopiatorRepository` in Info.plist.

**Privacy:** the app asks before its first network request. If allowed, at launch it requests only the public release lists of `berkbb/copiator-mac-universal` and `RsyncProject/rsync`.

## Known limitations and unverified points

- The x86_64 slices (app and rsync) build and link correctly, but could not be run on this Mac (macOS 27 without Rosetta). They should be tried on an Intel Mac.
- The real-app stress round and screenshots need Accessibility and Screen Recording permissions that the development session did not have; the UI was verified through off-screen rendering tests and snapshots instead. The Finder service, notifications and drag and drop should be tried by hand.
- The app is ad-hoc signed and not notarized. Releases are distributed through GitHub Releases.
- Shortcuts and Siri, the menu bar window, the Dock tile and real disk mount/eject events were tested through the model and off-screen rendering; they should be tried by hand in the installed app (Shortcuts indexes the app's actions after it is launched from `/Applications`).
