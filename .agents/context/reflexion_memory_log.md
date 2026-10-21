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

## Episode 10: FAT Re-runs Copy Everything
- **Root Cause:** FAT stores modification times in 2-second steps; rsync's quick check sees every file as changed.
- **Guardrail:** Add `--modify-window=1` for FAT destinations; verify with a real FAT32 image that a re-run has no differences.
