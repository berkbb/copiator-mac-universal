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

## Episode 31: A Single Trim Let a Template Climb Out of the Destination
- **Root Cause:** `RoutePlacement.component` trimmed spaces, removed leading dots, then trimmed spaces again. ". .." lost its first dot and its space and came out as "..", so a folder template could stage a path above the destination. Found by `fuzzPlacementAndDatesStaySafe` minutes after the feature was written; the hand-written red-team case used "../.." and passed.
- **Guardrail:** trim spaces and leading dots in a loop until the value stops changing, and refuse staged targets with "." or ".." components (`redTeamPlacementNeverLeavesTheDestination` now uses ". ..").

## Episode 32: rsync -L Reads Attributes From the Link
- **Root Cause:** when building the placement staging tree, `rsync -L`/`--copy-unsafe-links` copied the referent's contents and times but took extended attributes from the symbolic link itself, so quarantine and Finder tags were lost; `-L` also followed links inside packages, turning `Versions/Current` into a copy and an absolute link into the contents of a file outside the source.
- **Guardrail:** copy the source's attributes onto each staging link, use `--copy-unsafe-links`, mirror packages with only package-internal relative links, and test tags, quarantine and package links in `LivePlacementTests`.


## Episode 33: A Fixed Sleep Before Cancel in the Resume Test
- **Root Cause:** `interruptedCopyResumesWithTheSameCommand` cancelled after 400 ms. With the larger suite running in parallel, the cancel sometimes landed before the same-name check finished, so no `.conflictsSettled` event existed and the test's expectation about the resolution failed (the same timing flaw as Episode 23).
- **Guardrail:** cancel once a progress event reports transferred bytes; never cancel on a fixed delay in engine tests.

## Episode 34: The On-Device Model Wrapped Tokens in Brackets
- **Root Cause:** asked for a name template, Apple's on-device model answered `123456789_El_({month}_{yy}).pdf`: right idea, wrong form. Model output cannot be used as is.
- **Guardrail:** `Suggestions.cleanTemplate` strips quotes, brackets, prefixes and extensions and validates tokens; ranking answers are reduced to candidate numbers. Tests use a fake model; a live smoke test only checks that results are valid.


## Episode 35: Packages With the Same Total Size Looked Identical to Sync
- **Root Cause:** `SyncPlanner.same` treated two package folders (.app, .photoslibrary…) as the same when their total sizes matched, so a changed package whose files happened to add up to the same size was never synced. Found when a mutation (sync with `--delete`) went unnoticed and the package test written to catch it failed for this other reason.
- **Guardrail:** packages are compared file by file (`sameTree`: same names, sizes, and equal times or SHA-256); `packagesAreCopiedWithoutDeletingInside` also proves that a sync never deletes inside a package.

## Episode 36: Name Fixes Renamed Files That Had No Fixes
- **Root Cause:** the first version of `RoutePlacement.target` ran every name through `component()` after the (empty) fix list, so with only a folder template `.gizli` became `gizli` and `a:b.txt` became `a-b.txt`. No existing test pinned the name of a file whose route had no name template.
- **Guardrail:** names change only when a name template or a fix with a pattern exists; `namingModes` asserts that hidden and `:` names pass through unchanged, and the mutation round checks that guard.

## Episode 37: A Real Account Number in Tests and Docs
- **Root Cause:** an example template copied from the user's own scripts carried what looks like a real subscriber number into tests, README, CHANGELOG and a code comment (commit 178c8b4, not pushed). A test folder also used the user's first name.
- **Guardrail:** examples and fixtures use dummy values (`123456789`, `987654321`, `Belgeler(MacBook)`-style names); before writing a sample from the user's files, replace every identifier. Search with `grep -rI` over the working tree, not `git grep`: the first sweep used `git grep` and missed two untracked test files. The pushed history has no copy; the unpushed commit still does and needs the user's decision.

## Episode 38: The App Fixture Already Had Files in Its Source Folder
- **Root Cause:** the first app test for suggested placement used `Kaynak`, where `Fixture` already writes `not.txt` and `alt/b.txt`; three files were undecided instead of one, so the job kept asking after the test answered for one file.
- **Guardrail:** app tests that count selected files use their own source folder (`Faturalar`), not the fixture's `Kaynak`.

## Episode 39: A Local Model Server Is Not Automatically Local
- **Root Cause:** the user's Ollama lists cloud models (`…:cloud`, `remote_host: https://ollama.com:443`) next to local ones; picking one would send file names and contents to the internet through 127.0.0.1. A local server can also redirect a request elsewhere, and a system proxy could see localhost traffic.
- **Guardrail:** `LocalModelServer` filters cloud models from the list and `LocalServerSuggestionModel` refuses them by name, the address is fixed to 127.0.0.1, the session has no proxy, cache or cookies, redirects are refused (`localServersAreAskedOnLoopbackOnly` redirects to a 200 endpoint so following it would pass), and only 200 responses from 127.0.0.1 are read.

## Episode 40: Two Suites Raced on the Shortcut Target
- **Root Cause:** `IntentTarget.model` is one process-wide closure. `AutomationAppTests` and `RoutineAppTests` are each `.serialized`, but they run in parallel with each other; a routine test reset the target to `AppModel.shared` while the shortcut test was still calling it, so "job not found" came from another model. Added suites shifted the timing and exposed it.
- **Guardrail:** tests that set `IntentTarget.model` take `IntentTargetLock` first (an async FIFO lock on the main actor) and release it after restoring the target.

## Episode 41: A Successful Push Reported as Rejected
- **Root Cause:** git spoke HTTP/2 to GitHub. GitHub's activity log shows a single push (f0594b0 → 623b80a) and the local tracking ref was updated by that push, yet the client printed `cannot lock ref 'refs/heads/main': is at 623b80a but expected f0594b0`: the ref update was sent a second time after the server had applied the first one.
- **Guardrail:** the repository is pinned to `http.version HTTP/1.1` (local git config). After every push, `git ls-remote origin refs/heads/main` must equal the local SHA and the GitHub activity log must show exactly one push; a reported rejection is checked on the server before anything else, never retried blindly and never force-pushed.

## Episode 42: The Model Copied the Example Answer
- **Root Cause:** the three-language evaluation (`AIEvaluationTests`) showed Apple Intelligence picking the third candidate first in 8 of 9 folder questions, in every language: the ranking and placement instructions said "for example: 3, 1". The placement prompt also showed an example new folder, and the folder-template prompt's example was exactly the answer the evaluation expected, which would have inflated that score. Name templates failed for every model because the instructions did not say to keep the examples' fixed text instead of the new file's words; one answer also ended with a dot.
- **Guardrail:** instructions describe the answer format but never contain an answer that can be copied (`instructionsHaveNoAnswersToCopy`); `cleanTemplate` trims trailing dots and spaces; every prompt change is measured with `COPIATOR_AI_EVAL=1` before and after.

## Episode 43: Apple's Model Chose by Position, Not by Meaning
- **Root Cause:** with the example numbers removed from the prompts, Apple Intelligence still picked the first candidate in English and Romanian (before, it picked the third, copying "3, 1"): the small on-device model answers with a list position, not the folder that fits. Accuracy went from 5/18 to 3/18 while Ollama stayed at 15/18.
- **Guardrail:** Apple chooses by folder name through guided generation (only listed names can be produced), with greedy sampling, and is asked twice with the list reversed; disagreeing answers are not used (`byNameChoiceCatchesPositionalBias`). Templates must reproduce the destination's examples. Real fine-tuning (a LoRA adapter for the system model) needs Apple's adapter toolkit and entitlement and is on the roadmap as a decision.

## Episode 44: Templates Were the Wrong Job for a Language Model
- **Root Cause:** both models failed most name and subfolder templates even after prompt fixes, yet a template is fully determined by the examples' fixed text and date parts. Asking a 2–3B model to derive it was slower and less reliable than a deterministic rule.
- **Guardrail:** `TemplateInference` derives templates by rule first and a model is asked only when the rule finds nothing; every template must still reproduce the examples. A single odd example must not decide the template (the fallback group needs at least two examples), and folder templates never get a `{name}` part.

## Episode 45: Apple's Guardrails Refuse Insurance, Tax and Health Files
- **Root Cause:** in the 81-question evaluation Apple Intelligence returned errors (counted as "engine unavailable") only for insurance, tax return, health insurance, prescription and vaccination files: its safety guardrails refuse these topics. The rule baseline (`FolderSuggester` top choice) already chose 28 of 30 folders with contents, more than Apple's 21. A full test run right after the evaluation also failed a timing-sensitive pause test once while Ollama's 8 GB model was still loaded on the 16 GB Mac; alone it passed three times in a row.
- **Guardrail:** a guardrail refusal is just another failed attempt: Automatic moves on to the next model and the rule order stays, never an error dialog. Measure the Automatic chain, not only single models, because that is what users see; unload local models (`ollama stop`) before running the full suite after an evaluation.

## Episode 46: Apple Answered First and Pre-empted the Better Model
- **Root Cause:** in Automatic mode Apple answers first; when it was confident (consensus and its own fit check passed) its wrong existing-folder picks for documents with no fitting folder (a lease or a diploma under payslips) were used and Ollama was never asked. Automatic scored 71/81 while Ollama alone scored 74.
- **Guardrail:** Apple's existing-folder picks are cross-checked by the next ready model and its decision wins on disagreement (`automaticCrossChecksApplesFolderPicks`). Automatic then matched Ollama alone (73/81, run-to-run variance is about one question) with fewer wrong suggestions (7 instead of 10).

## Episode 47: Skipping a Hidden File Skipped the Whole Folder
- **Root Cause:** the integrity walk called `NSDirectoryEnumerator.skipDescendants()` for every skipped name, including `.DS_Store`. Called while the enumerator stands on a file, it skips the rest of the enclosing directory, so a folder listed after `.DS_Store` was never checked. `Suggestions.exampleFolders` had the same pattern for its depth limit.
- **Guardrail:** call `skipDescendants()` only when the current item is a directory (checked with `lstat`); `archiveIntegrityFindsSilentCorruption` puts a `.DS_Store` before a subfolder and a mutation that drops the directory check fails it. Recorded in the code graph impact map.

## Episode 48: A Safety Check That No Test Could Reach
- **Root Cause:** mutation testing removed the re-hash before moving a duplicate to the Trash and the test still passed: the test changed the file's size after the scan, so the earlier size check already refused it and the content check was never exercised.
- **Guardrail:** when guards are layered (size, then contents), each test case must get past the earlier guards and be caught only by the one under test; the duplicate test now changes the contents without changing the size. All 11 guards of the archive health features were checked by removing them.


## Episode 49: Spotlight Answered One Spelling Before the Other
- **Root Cause:** under the full suite's load (integrity hashing, live rsync runs) `SpotlightContentTests` found the new file for the lowercase word but not, a moment later, for the uppercase spelling: the index was still settling and only the first query waited for it. Alone the test passed three times in a row.
- **Guardrail:** every query against an external, eventually consistent index waits for its own result (the test's `search` helper polls each spelling); only the expected-empty query is asked once.

## Episode 50: A Folder's Volume Name Is Not the Disk's Name
- **Root Cause:** the eject log and notification first took the disk name from `volumeLocalizedName` of the volume URL. In the app test the fake disk is a folder on the internal disk, so the name came back as the internal disk's name; on a real mount point both agree, which hid the dependency.
- **Guardrail:** names shown for a disk come from `FileManager.displayName(atPath:)` of the mount point; `LiveDiskEjectTests` checks on a real APFS disk image mounted at a custom folder that the shown name is the volume name, not the folder's.


## Episode 51: A Build Error Counted as a Surviving Mutant
- **Root Cause:** the mutation harness classified a run as a build error only when the output contained ": error:", but the Swift driver printed "error: <path>:<line> …" for a test that used the keyword `internal` as a variable name. Three mutants were reported as missed although no test had run.
- **Guardrail:** a mutation run counts as caught only with a failed test (✘) and as missed only when "Test run with" appears; anything else is a build error that must be fixed first. Always run the edited test once before mutating.

## Episode 52: The Stress Probe Never Looked Inside the Job List
- **Root Cause:** `Scripts/StressProbe.swift` came from a project whose outlines hold tens of thousands of archive entries, so it skipped every `AXOutline`, `AXTable` and `AXRow`. Copiator's job list is an outline (`copiator.joblist`), so `copiator.job.toggle` was never found, pause and resume failed, and the copy checks that followed reported an unfinished copy.
- **Guardrail:** the probe searches the job list's rows and still skips other long lists; when a probe reports "element not found", measure the real accessibility path (the button sat at depth 12) before suspecting the app.

## Episode 53: Notifications Passed Every Test and Never Appeared
- **Root Cause:** every notification test injects `notifier`, so the suites proved what the app asks for, not what macOS shows. In the installed ad-hoc signed app, `requestAuthorization` fails with "Notifications are not allowed for this application", and the Dock does not show Copiator's badge, although `DockProgress.update` runs with the right values.
- **Guardrail:** features that go through the operating system (notifications, Dock tile, App Intents) are checked in the real, signed bundle before a release, with a bare probe app to separate system policy from app code; a release does not claim them until that check passes.

## Episode 54: The Check on Connect Raced the Backup on Connect
- **Root Cause:** `volumeDidMount` started the integrity check at once, in parallel with the job that also starts on that disk, so the first check recorded an empty folder and could have recorded rsync's temporary files as later "missing" ones.
- **Guardrail:** checks on connect wait in `pendingIntegrityChecks` until `DiskEject.isBusy` is false for the volume, and `integrityOnConnectWaitsForTheDisksJobs` (with two guards checked by mutation) keeps the order: jobs, then the check, then the eject.

## Episode 55: Blaming the System for a Dock Bar the App Never Drew
- **Root Cause:** the Dock showed no progress for Copiator, and after a bare test app under Copiator's bundle id could not show a badge, the report blamed system policy. The user remembered a green bar, which came from the sister download app: it draws its tile itself, while Copiator placed a system `NSProgressIndicator` on the tile, which never appeared in the Dock (a build from before the session behaved the same). Requesting notification permission without `.badge` also keeps a registered app's drawn tile hidden.
- **Guardrail:** when a user says something used to work, compare with the sister app or an older build before concluding; the Dock tile is drawn (`DockTileView`), notification permission includes `.badge`, and `DockProgressTests` checks the drawn pixels. A live check during a real copy is part of the hands-on round.

## Episode 56: Blaming the Signature for a Prompt the Location Withheld
- **Root Cause:** notifications never appeared and `requestAuthorization` failed with UNErrorDomain 1, so the report pointed at the ad-hoc signature and parked the problem behind Developer ID (roadmap 11). The comparison mixed two variables: the copy that got the prompt was both differently signed and opened from `/Applications`. An ad-hoc probe copied to `/Applications` got the prompt too; the same probe in `/tmp` or `build/` did not.
- **Guardrail:** change one variable at a time before blaming signing or system policy; for privacy features test the installed app in `/Applications`. Copiator now asks at launch and explains a blocked permission in a banner (`PermissionTests`), and hands-on rounds run from `/Applications`.

## Episode 57: Deleting the Backup in the Same Command as the Check
- **Root Cause:** after a hands-on round the settings were restored with `defaults import` and compared with the backup, but the same shell command also deleted the backup, so when the comparison reported a difference (most likely AppKit's own window and open-panel state) there was nothing left to compare or restore from. The job list matched; the user settings visibly did too.
- **Guardrail:** delete backups only in a separate step after the comparison passed; when a restore check fails, keep the backup and report the exact difference. During UI rounds, check that the app is frontmost before every keystroke, prefer accessibility actions over keys, and keep the display awake with a time-limited `caffeinate -d` that is stopped afterwards.

## Episode 58: A Flaky Test That Was a Real Bug
- **Root Cause:** "undo last run" decided whether a file was created by the run from its creation time. rsync `-t` sets the copy's modification time to the source's, and macOS then moves the creation time back to it, so every copy of an older source file looked older than the run and undo would have moved nothing in real use. The tests passed because their source files were written seconds before the run; under parallel load the gap grew past the 2-second tolerance and the test failed only sometimes.
- **Guardrail:** time-based evidence must be checked against realistic data (old source files, preserved times); the undo test now uses year-old sources and the decision uses the status-change time. A test that fails only under load is investigated with recorded timestamps before it is called flaky.


## Episode 59: Undo That Sent Both Sides to the Trash
- **Root Cause:** "undo last run" knew only what a run created at the destination. A run with "Move to the Trash after copying" had also moved its sources to the Trash, so undoing it moved the copies there too and left the only copies of the files in the Trash. Found by comparing Copiator with the `ev` scripts, whose undo puts moved files back. The same comparison showed the undo log line printing pointer-sized numbers: log arguments are stored as text, and the string used `%ld`.
- **Guardrail:** the trash step returns where each item went (`SourceTrash.systemTrashLocating`) and the undo record carries it; `RunUndo.restoreSources` puts sources back first and keeps the copy of any source it cannot restore. `logStringsTakeTextArguments` keeps every `log…` string on `%@`. When adding a destructive step, check what its undo means for the other side of the copy.

## Episode 60: `standardizedFileURL` Is Not a Neutral Normalizer
- **Root Cause:** archive search built relative paths from `url.standardizedFileURL.path`, which turns "/private/var/…" into "/var/…" while the resolved root kept "/private", so every result fell back to its bare file name.
- **Guardrail:** compare paths that come from the same source of truth (the enumerator's raw `url.path` against the resolved root); use `standardizedFileURL` only on both sides of a comparison, never against a `realpath` result.

## Episode 61: A Timeout on the Shared Pool
- **Root Cause:** the 1.2.0 release run failed `runnerTimesOut` (no timeout for `sleep 5` with a 0.3-second limit), while five full runs before it passed. Instead of calling it flaky, a measurement showed that a `DispatchQueue.global().asyncAfter` timer fired after 8.8 seconds while the shared pool was full of blocking work; a private serial queue fired on time. A private *concurrent* queue did not help: it waits for the same pool. `CommandRunner` used the shared pool for the timeout, the forced stop and the blocking wait for the last output.
- **Guardrail:** timers live on `CommandRunner.timers` (serial), the drain wait on its own thread; `runnerTimesOutWhileTheSharedPoolIsBusy` fills the pool briefly and fails when the timeout goes back to the shared pool (checked by doing exactly that). A test that fails only under load gets a measurement before it is called flaky.


## Episode 62: A Rule Changed at One Entry Point but Not Its Twin
- **Root Cause:** when an unplugged disk stopped being an error, `saveRoutine`, `runRoutine` and the import switched to `JobValidation.check(allowUnmounted: true)`, but `runRoutine(_:on:)`, which serves "Send to Routine" (Finder service, drops, Shortcuts), kept the strict check. Sending items to a routine with a route to YEDEK while the disk was unplugged refused the whole send. It surfaced only when the user asked whether the Finder service works from other folders.
- **Guardrail:** when a validation rule changes, list every caller of the validator (`grep "JobValidation.check("`) and every entry point that queues the same kind of job, and decide for each. `sentItemsWaitForAnUnpluggedDisk` covers the send path and fails with the strict check (verified).


## Episode 63: Arhivar's 2026-11-08 Lessons Applied Here Before They Could Bite
- **Context:** Arhivar's 7-Zip update failed on 2026-11-08 because GitHub's Frankfurt edge answered 504 for every `releases/download` URL while the API worked; the same day its tests were found to have left thousands of empty plists in `~/Library/Preferences`. Copiator shares both patterns: `update-rsync.sh` had one download URL, and the `Fixture` and `SettingsTests` opened plain-named `UserDefaults` suites (about 4,900 `CopiatorAppTests-…plist` and `CopiatorSettings-…plist` files were on this Mac).
- **Solution & Guardrail:** `update-rsync.sh` reads the asset's API URL from the release listing it already fetches, accepts it only under `api.github.com/repos/RsyncProject/rsync/releases/assets/` and retries the download there with `Accept: application/octet-stream`; the SHA-256 check is unchanged. `package.sh` fails when `lipo -archs` of the bundled rsync lacks an architecture in `ARCHS`. `LaunchServicesRegistration.registerIfBuildChanged()` re-registers the bundle on the first launch of a new build (never in the test bundle). Tests open settings only through `TestDefaults` (Descarcator's class, path-named domains in a temporary folder, `CFPreferencesAppSynchronize` before deleting), `TestDefaultsTests` scans `Tests/` for any other suite opening, and `package.sh` compares `~/Library/Preferences` before and after the run.
- **Pitfall:** the scanning test flagged its own doc comment, which quoted `UserDefaults(suiteName:)`; comments in that file must not spell the pattern.
- **Same day:** `update-rsync.sh check` showed rsync 3.5.2 (4 Nov 2026: CVE-2026-119741, interrupted `--append`/`--inplace` writes, an out-of-bounds write after a read error). Because the in-app update needs the Command Line Tools, the new engine ships as Copiator 1.2.1; `update-rsync.sh install` took the github.com path (the edge had recovered), so the API fallback has still only been exercised by reading the script, not by a failed download.
- **Not covered:** when `api.github.com` itself is unreachable both the rsync check and the app update check fail with "Could not reach GitHub" (correct, no mirror). The old plist files were left in place.

## Episode 64: rsync 3.5.2 Changed Its Progress Numbers and Escapes Turkish Letters in the C Locale
- **Context:** the first full test run with the vendored rsync 3.5.2 (built for 1.2.1) failed nine tests: every progress-driven test (`fraction` nil, interrupted copies that never interrupted and then asked for a decision), the conflict red-team test and the diagnostics report, plus the three tests that spell the version.
- **Evidence:** the 3.5.1 and 3.5.2 binaries were run side by side on the same folder with Copiator's flags. 3.5.2 prints `15,000B  99%       0B/s`, `3.00MB  99%    231MB/s`, `1B 100%      83B/s`; 3.5.1 printed `15,000  99%    0.00kB/s`, `3.00M`, `0.09kB/s`. With an empty environment (`env -i`, as Launch Services starts an app) 3.5.2 wrote `Foto\#237raflar` for `Fotoğraflar` while 3.5.1 and 3.5.2 under `LANG=en_US.UTF-8` wrote the raw bytes: the new "escape terminal control characters" rule treats UTF-8 continuation bytes 0x80–0x9F as C1 controls in the C locale, and `ğ`, `ş`, `Ğ`, `Ş` all have one. Swift had already decoded stdout as a String, so the lone 0xC4 became U+FFFD and `ItemizeParser.unescape` could not repair it.
- **Second measurement:** with `-8` the itemized names were raw again, but the unreadable-file error on stderr still read `okunamaz \xC4\#237.jpg`: `-8` covers the file list only. `LC_CTYPE=UTF-8` (or `LC_ALL=en_US.UTF-8`) in the child's environment fixed both; `CommandRunner.childEnvironment` adds it when `LC_ALL`, `LC_CTYPE` and `LANG` name no UTF-8 locale, and drops a non-UTF-8 `LC_ALL`.
- **Solution & Guardrail:** `RsyncProgressParser.parseBytes` strips a trailing `B`, `parseRate` knows `B/s`, `KB/s` and `TB/s`; `parsesRsync352ProgressLines` keeps the 3.5.2 lines. `baseFlags` adds `-8` (`-rltDh8X`), which openrsync also accepts; the 3.5.1 escaping of real control characters is unchanged. The release NEWS said "escaped terminal control characters in filenames … while preserving printable text in the active locale", which is only safe when the process has a locale: an app launched from Finder has none. After every engine update, run the full suite with the new binary before touching the version number, and diff the engine's output with the old binary under `env -i`, not only in a shell that has `LANG`.
