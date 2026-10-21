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
│   │   ├── RsyncCommand.swift       Every rsync argument (transfer, verify), file-system aware flags, exclusions
│   │   ├── RsyncProgress.swift      TransferProgress + --info=progress2 parser
│   │   ├── RsyncOutcome.swift       Exit code + stderr → JobResult (harmless FAT/exFAT warnings, full/read-only/permission…)
│   │   ├── ItemizeParser.swift      `-i` output → DiffEntry (missing, changed, attributes, extra)
│   │   ├── Engine.swift             EngineLocator (candidates, version parsing, choosing), EngineUpdater (update-rsync.sh)
│   │   ├── TransferEngine.swift     Engine-independent protocol, events, EngineContext, VerifyReport, engine registry
│   │   ├── RsyncEngine.swift        The rsync implementation: preflight, sandbox, disk guard, progress throttle, quarantine
│   │   ├── Job.swift                TransferJob, CopyOptions, JobStatus, JobResult, JobLogEntry, JobValidation (Codable, backward compatible)
│   │   ├── JobStore.swift           jobs.json persistence (atomic, corrupt files set aside) and JobQueue rules
│   │   ├── DiskSpace.swift          DiskSpace, DiskSpaceGuard, FileSystemKind, OwnerAccess, saturating Int64
│   │   ├── Quarantine.swift         Keeps com.apple.quarantine when xattrs are not copied
│   │   ├── SleepAssertion.swift     IOPMAssertion (caffeinate -i equivalent)
│   │   ├── OpenSafety.swift         Visible rendering of deceptive characters in paths
│   │   ├── AppUpdate.swift          GitHub release check, Ed25519 signature and SHA-256 verification
│   │   └── Localization.swift       AppLanguage, StringTable, LKey (all string keys)
│   └── Copiator/                  SwiftUI app (default isolation: MainActor)
│       ├── CopiatorApp.swift        Scenes, menu commands, AppDelegate
│       ├── AppModel.swift           Engine probing, queue execution, pause/resume, verify, updates, persistence
│       ├── AppSettings.swift        UserDefaults preferences, shortcuts, localization and formatting
│       ├── FinderServices.swift     "Back Up with Copiator" service
│       └── Views/                   ContentView (overlay, toast), job list and inspector, New Job, Verify, Settings, About, license viewer
├── Resources/                     {tr,en,ro}.lproj/{Localizable,InfoPlist,ServicesMenu}.strings, AppIcon.icns
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
- **Engine layer:** a job carries a `JobKind`; `TransferEngines.engine(for:)` returns the `TransferEngine` (today only `RsyncEngine`). A remote rsync or another engine is added as a new kind; queue, persistence and UI stay the same.
- **Queue:** `AppModel` runs one job at a time: the first `waiting` job in list order. Events travel through an `AsyncStream` and are applied in order on the main actor; the result is written only after all events. A started job switches to `scanning` immediately. Pause cancels the task (rsync gets SIGTERM, keeps the partial file, exits 20) and the job becomes `paused`; resume requeues it with the same command. While a job runs, an `IOPMAssertion` prevents idle sleep.
- **Persistence:** `JobStore` writes `~/Library/Application Support/Copiator/jobs.json` atomically. Decoding is tolerant (missing fields get defaults; unknown kinds, statuses or result kinds fall back). An unreadable file is renamed to `jobs.corrupt-<time>.json` and reported. On quit the running job is stopped and saved as interrupted; at launch it comes back paused (or waiting with "Resume interrupted jobs at launch").
- **Disk space:** before copying, the source size minus the matching data already at the destination must fit, leaving a reserve of 1 GB (at most 2 % of the volume, so small USB sticks stay usable). While copying, `DiskSpaceGuard` stops rsync when free space drops below 512 MB (half the reserve for small volumes); the job can be resumed after freeing space.
- **Engine selection:** candidates are the custom rsync (Settings), the bundled one, `~/Library/Application Support/Copiator/engine`, Homebrew and `/usr/bin/rsync`. A working custom rsync always wins; otherwise the newest full rsync wins, and macOS's openrsync (no `--info=progress2`, no `-X`/ACLs) is used only as a last resort in a limited mode.

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
- If the app crashes (rather than quits) while a job runs, the rsync process may keep running until it finishes; the job comes back paused at the next launch.
- The app is ad-hoc signed and not notarized.
