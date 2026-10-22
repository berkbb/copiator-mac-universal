# Reflexion Memory Log — Self-Correction & Episodic Memory

> **Memory Category:** Google DeepMind Reflexion Asset (Episodic Memory & Self-Correction)
> **Scope:** Non-obvious root causes and verified lessons discovered while building Copiator 1.0 (2026-10-21).

---

## Episode 1: No Rosetta → x86_64 `configure` Cannot Run Its Test Programs
- **Context:** Building a universal rsync on Apple Silicon running macOS 27.
- **Root Cause:** `arch -x86_64 /usr/bin/true` fails ("Bad CPU type"): no Rosetta, so autoconf's run tests for an x86_64 build cannot execute.
- **Guardrail:** Configure arm64 natively with `--cache-file`, strip `ac_cv_env_*`/host/compiler entries from the cache, and cross-configure x86_64 with `--host=x86_64-apple-darwin` plus the cached results (`Scripts/build-rsync.sh`). The x86_64 slice cannot be run-tested on such a Mac; say so.

## Episode 2: rsync Git Tags Lack `configure.sh`; `.git` Changes the Version
- **Root Cause:** `configure` calls `prepare-source`, which needs `aclocal` (automake) to regenerate `configure.sh`; and `mkgitver` turns the version into `3.5.1-g<commit>` whenever `.git` exists.
- **Guardrail:** Recreate `aclocal.m4` from `m4/*.m4` with `m4_include` lines (rsync uses no automake macros), run `autoconf`/`autoheader`, record the commit, then delete `.git`. The result is byte-identical to the release-tarball build.

## Episode 3: `cmd | grep -q` Under `set -o pipefail`
- **Root Cause:** `grep -q` exits on the first match and closes the pipe; the producer dies with SIGPIPE and `pipefail` reports failure although the text was present.
- **Guardrail:** Capture the output once (`TEXT="$(cmd)"`) and grep the variable.

## Episode 4: A 1 GiB Reserve Makes Small USB Sticks Unusable
- **Context:** Real FAT32/exFAT disk images of 64 MB refused a 4-byte copy.
- **Root Cause:** The fixed system-volume reserve (1 GiB) and 512 MiB floor exceeded the whole volume.
- **Guardrail:** Scale both to the destination volume: `min(1 GiB, capacity/50)` and half of it (`DiskSpace.reserve(forVolumeCapacity:)`). Always test against real small volumes (`COPIATOR_VOLUME_TESTS=1`).

## Episode 5: Cancel Hung Until a Grandchild Exited
- **Root Cause:** The runner waited for EOF on stdout/stderr; a killed shell's `sleep` child kept the pipe open for 30 s.
- **Guardrail:** After the process exits, wait at most `CommandRunner.drainGracePeriod` (2 s) for the readers, then deliver the result and ignore later output.

## Episode 6: Quit Marked the Job Interrupted, Then the Completion Handler Un-marked It
- **Root Cause:** `prepareForTermination` saved `paused + wasInterrupted`, but the cancelled task's `finishRun` later applied `JobQueue.finish(.cancelled)`, clearing the flag and logging a plain pause.
- **Guardrail:** An `isTerminating` flag makes `finishRun` keep the interrupted state and stops the queue from starting the next job.

## Episode 7: A Started Job Looked "Waiting" and Could Be Removed
- **Root Cause:** The status changed only when the engine's first event arrived on the main actor; between `start` and that event, `JobQueue.canRemove` was true while rsync was already running.
- **Guardrail:** `AppModel.start` sets `.scanning` synchronously.

## Episode 8: Substring Error Classification Is Fooled by File Names
- **Root Cause:** Checks like `stderr.contains("No space left on device")` or `contains("chown ")` match file names such as `No space left on device (28).txt` or `chown notes.txt`.
- **Guardrail:** Match at rsync's message position (`RsyncOutcome.messageBody`) or as the line's trailing errno text (`endsWithErrno`). Tested in `fileNamesDoNotFakeErrorClasses`.

## Episode 9: A Sandbox Network Test Must Prove the Sandbox Blocked It
- **Root Cause:** Connecting to a closed local port fails with or without a sandbox.
- **Guardrail:** Assert `Operation not permitted` under the sandbox and `Connection refused` without it (`networkIsDenied`).

## Episode 11: `--link-dest` Silently Copied Instead of Linking Under the Sandbox
- **Root Cause:** macOS's sandbox treats `link()` as a write on the existing file. With the previous backup outside the writable destination, rsync's link failed and it fell back to a full copy without an error. No individual operation (`file-link`, `file-write-create`, …) is enough; only `file-write*` on the reference works.
- **Guardrail:** grant write access to the `--link-dest` reference only; assert identical inodes in a live test (`linkDestSnapshots`). Do not trust exit code 0 for "linked".

## Episode 12: A File-Level Allow Does Not Let rsync Read a List in a Denied Folder
- **Root Cause:** rsync 3.5.1 opens `--files-from`/`--*-from` files component by component (symlink-safe open), so it needs to read the denied folder itself; `cat` with the same profile works.
- **Guardrail:** the app reads list files itself and passes a private temporary copy (`stageListFiles`); never open the whole personal folder.

## Episode 13: Shared Assertion Names Make Parallel Tests Lie
- **Root Cause:** suites run in parallel; every model used the reason "Copiator copy job", so "still present after release" was true because of another suite's job.
- **Guardrail:** `AppModel(sleepReason:)` is unique per test model; verification compares exact names.

## Episode 10: FAT Re-runs Copy Everything
- **Root Cause:** FAT stores modification times in 2-second steps; rsync's quick check sees every file as changed.
- **Guardrail:** Add `--modify-window=1` for FAT destinations; verify with a real FAT32 image that a re-run has no differences.

## Episode 14: Swift Testing Suites Share One Process
- **Root Cause:** core and app test targets run in one test process; a test that sets global state (`ChildProcessGuard.configure(stateFile:)`) can redirect another suite's records mid-test.
- **Guardrail:** tests of global registries assert only additive in-memory state (`registeredPIDs`); file persistence of the registry is checked once, in the app's launch-reaping test.

## Episode 15: Off-Screen Snapshots Lose Light Text
- **Root Cause:** `cacheDisplay` draws only the hosting view; non-`Form` views have no background, so dark-mode text vanished on a transparent PNG.
- **Guardrail:** the render helper draws `windowBackgroundColor` behind every view.

## Episode 16: App Intents Metadata Is Not Produced by SwiftPM
- **Root Cause:** SwiftPM's build emits `*.swiftconstvalues` but, unlike Xcode, never runs `appintentsmetadataprocessor`, so Shortcuts would not see the actions.
- **Guardrail:** `Scripts/build_app.sh` runs the processor and bundles `Metadata.appintents`; `verify_bundle.sh` fails if an action or the Siri phrases are missing. `@Parameter` properties cannot live in a `nonisolated struct` under default MainActor isolation; keep that intent main-actor and mark its static metadata `nonisolated`.

## Episode 17: A Wrapping Banner in `safeAreaInset` Crashed the App When a Job Started
- **Root Cause:** `PowerStatusBanner` (shown above the job list while a job runs) used `.fixedSize(horizontal: false, vertical: true)`, so the detail column's minimum height depended on its width. In the real window (min size taken from the content, toolbar bridged) the split view re-evaluated column sizes on every pass until AppKit raised `NSGenericException` ("more Update Constraints in Window passes than there are views"). Plain `NSHostingView` render tests never ran that path, and an on-screen check was not possible without Accessibility permission. Introduced with the power banner in commit 3b96b34; found when the user added a single-file job.
- **Guardrail:** `ui_rules.md` §6; `WindowLayoutTests` hosts `ContentView` in an `NSHostingController` window (toolbar bridging, off-screen, display cycle running) and adds and runs jobs. Verified to crash without the fix and pass with it.
- **Side finding:** macOS's own `/usr/bin/rsync` failed under the sandbox; fixed in Episode 18.

## Episode 18: macOS's openrsync Never Worked Under the Sandbox
- **Root Cause:** openrsync runs its local receiver with `execvp("rsync")`; Homebrew's rsync came first in `PATH`, and the sandbox only allows the engine itself (`EPERM` → "exec on 'rsync'"). After that, `--extended-attributes` made it create `/private/tmp/.<pid>.._name` AppleDouble files (denied) and made `-n` runs open nonexistent `._` files. Its `-i` output is 9 columns, so verify found nothing. Earlier tests only checked openrsync's arguments, never a live run.
- **Guardrail:** `--rsync-path=<resolved engine path>` for openrsync only; no xattr flag for openrsync (quarantine still propagated, `-X` logged as dropped); `ItemizeParser.Format`. `SystemRsyncTests` copies, verifies and checks quarantine with `/usr/bin/rsync`, sandboxed and not, with a decoy `rsync` first in `PATH`.

## Episode 19: `--from0` After `--exclude-from` Silently Used Only the First Pattern
- **Root Cause:** rsync parses an `--exclude-from` file when it reads that option; `--from0` placed later did not apply, so the NUL-separated list was read as one line and only its first pattern (up to the first NUL) excluded anything. `--files-from` is read later, so routines were unaffected, which hid the problem.
- **Guardrail:** `RsyncCommand.exclusions` emits `--from0` first; `from0PrecedesListOptions` checks transfer, verify and conflict-check arguments; live tests check that skipped files keep their old contents.

## Episode 20: `--link-dest` Made Absent Files Look Present
- **Root Cause:** with a reference directory, `rsync -n -ii` reports files matching the previous backup as unchanged even though the destination is empty, so the conflict check saw "same-name files" that did not exist.
- **Guardrail:** `RsyncCommand.conflictCheck` drops reference-directory options.

## Episode 21: Spotlight Folds Case With the System Locale
- **Root Cause:** the content criterion relied on the `c` modifier of `kMDItemTextContent == "*text*"cd`. On a Mac set to Turkish, Spotlight indexes and folds "I" as "ı" and "İ" as "i", so "isparta" did not find a file containing "Isparta" and an uppercase search with "I" missed lowercase text. Unit tests only checked the query string; the gap showed up in the first test against a real index (`mdimport` + `MDQuery`).
- **Guardrail:** `Spotlight.query(for:)` searches each i-like letter as both "i" and "ı"; `SpotlightContentTests` indexes a real folder under `build/` (temporary folders are not indexed) and checks the dotted/dotless variants. It runs only when `mdutil` reports indexing enabled.

## Episode 22: Jobs Saved Before a New "Ask" Default Asked Every Time
- **Root Cause:** the same-name policy defaults to Ask, so jobs and routines saved before the setting existed suddenly asked on every run, although their users never chose that.
- **Guardrail:** `CopyOptions.suggestsRememberingConflictChoice` is decoded as true when the saved options have no `conflictPolicy`; the conflict sheet pre-checks "Remember" for them and `AppModel.resolveConflicts` clears the flag on the job and its routine. Covered by `conflictOptionsDecodeWithAskAsDefault` and `legacyJobsSuggestRememberingOnce`.

## Episode 23: An Opt-In Suite Hid a Regression From the Same-Name Check
- **Root Cause:** `StressTests` runs only with `COPIATOR_STRESS_FILES`, so the full suite skipped it after the same-name check was added. Its cancel-then-resume step drove the engine directly without applying `.conflictsSettled` to the job, so the resumed run stopped as "Needs decision". A fixed one-second cancel also made the outcome depend on tree size: with 20000 files the cancel fell inside the conflict check and the test still passed.
- **Guardrail:** the test cancels once bytes are being copied and applies the run's events with `JobQueue.apply`, as the app does. After a change to the engine's run flow, run the opt-in rounds too (`COPIATOR_STRESS_FILES=2000 swift test --filter StressTests`, `COPIATOR_VOLUME_TESTS=1 swift test --filter ForeignVolumeTests`).

## Episode 24: rsync Silently Deleted a File to Make Room for a Folder
- **Root Cause:** the same-name check only read `f` lines that were not new. When the destination held a file named like an incoming folder (or a link or empty folder where a file arrives), rsync showed the item as new (`cd+++`, `>f+++`) and deleted what was there; nobody was asked. Found by the red-team matrix case.
- **Guardrail:** `ConflictDetector` treats a new item whose path exists at the destination (`lstat`, parents must be real folders) as a conflict with `incomingFolder`; Keep Both renames the existing item. Covered by `redTeamItemsOfAnotherTypeAreAskedAbout` for every decision.

## Episode 25: An Escaped Backslash Never Matched
- **Root Cause:** `escapePattern` always escaped `\`. rsync treats a pattern as a wildcard pattern only when it contains `*`, `?` or `[`; otherwise it compares literally, so "/ters\\bölü.txt" never matched "ters\bölü.txt" and a skipped file was replaced. The unit fuzz test checked the escaping shape, not rsync's behavior.
- **Guardrail:** escape the whole pattern once and only when it is a wildcard pattern; `redTeamWildcardNamesAreExcludedLiterally` runs the real rsync.

## Episode 26: A Regex Could Hang a Scan Forever
- **Root Cause:** `NSRegularExpression.firstMatch` has no limit, and the scanner checks cancellation only between items, so `(a+)+$` on a 40-character name never finished (nor did the Try field on the main thread).
- **Guardrail:** `.reportProgress` with a step budget (a count, not a clock); `RunawayRegex` fails the job with `logRuleRegexTooComplex`.

## Episode 27: Unchecked Number Conversions in Rule Evaluation
- **Root Cause:** "within the last N days" converted the rule's `Double` to `Int` without bounds; validation accepted any finite positive number, so 1e19 crashed the app. Video sizes were converted the same way.
- **Guardrail:** clamp to `maxCalendarAmount`, range-check pixels; `volumeHugeRuleNumbersNeverTrap`, `volumeMediaPixelSizesAreRangeChecked`.

## Episode 28: Numbered Copies Lost the Quarantine Flag
- **Root Cause:** quarantine propagation runs on the main transfer's paths before keep-both copies exist; without `-X` (openrsync or attributes off) the numbered copy of a downloaded file had no quarantine.
- **Guardrail:** `copyKeepingBoth` writes the source's quarantine value on each numbered copy when attributes are not copied; `penetrationQuarantineReachesNumberedCopies`.

## Episode 29: Matrix Fixtures That rsync Considered Identical
- **Root Cause:** several new tests wrote "yeni" and "eski" (same size) in the same second; rsync's quick check (size + mtime) skipped them, so "replace" seemed broken. A 0555 folder also turned out not to block the owner's rsync, which makes it writable temporarily.
- **Guardrail:** fixtures for replacement use different sizes; "cannot write" scenarios use a Finder-locked (`uchg`) file.

## Episode 30: Pipe Readers Starved on the GCD Pool
- **Root Cause:** `CommandRunner` drained stdout and stderr with blocking reads on `DispatchQueue.global()`. When the matrix ran many processes beside other suites, a reader for `/bin/cat` was not scheduled before the 2-second `drainGracePeriod` that starts at process exit, so `runnerFeedsInput` saw empty output. `Process` itself does not leak pipe descriptors (checked with `lsof`).
- **Guardrail:** each pipe is drained on its own `Thread`; the grace period only covers grandchildren holding a pipe open.

