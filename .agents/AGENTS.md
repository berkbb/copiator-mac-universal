# AGENTS.md — Primary Constitution & L3 Persona Governance

> **Language Mandate:** All files inside `.agents/` (`AGENTS.md`, `context/`, `rules/`, `skills/`) **MUST** be written exclusively in English. Inline comments and docstrings inside `Sources/`, `Tests/`, and `Scripts/` may remain in Turkish as part of the developer's native workflow.

---

## 1. Project Identity & Mission

**Copiator** (`copiator-mac-universal`, bundle id `com.babadogantech.copiator`) is a native macOS 26 (Tahoe) universal (`arm64` + `x86_64`) local backup and sync app built with Swift 6.2 and SwiftUI (Liquid Glass). Its engine is `rsync`, run as a separate process inside an isolated kernel sandbox (`sandbox-exec`). License: **GPL-3.0-or-later**.

### Constitutional Invariants (Non-Negotiable)

1. **The Source Is Never Modified (by rsync):** the only exception is the opt-in "move to the Trash after copying" step decided by the user on 2026-10-22: the app (never rsync) moves a source file to the Trash only after its destination counterpart is verified to have identical contents (`SourceTrash.moveVerified`); nothing is deleted permanently.
   - `RsyncCommand` must never produce `--remove-source-files` (or `--remove-sent-files`); `RsyncCommand.assertSafe` and tests enforce this.
   - The sandbox denies writes to every source **after** allowing writes to the destination (SBPL: last match wins), so a source nested inside the destination stays read-only.
   - Jobs whose source and destination target overlap are refused (`JobValidation.check`).
2. **`--delete` Only When Chosen and Confirmed:** `CopyOptions.deleteExtraneous` defaults to `false`, is never a settings default, and the New Job sheet asks for confirmation. Verify adds `--delete` only together with `-n` (listing only) and with no writable sandbox folder.
3. **Process Boundary & GPL Compliance:** rsync is never linked. The bundled binary is built from the unmodified upstream tag by `Scripts/build-rsync.sh`; its provenance (tag, commit, flags, SHA-256) lives in `Vendor/rsync/SOURCE.txt`. Every Swift source starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
4. **Kernel Sandbox Isolation (`SandboxProfile.forTransfer`):** no network, writes only to the destination, no `process-exec` except rsync itself, no `mach-lookup`, personal-data folders read-denied unless chosen as the source (and excluded from larger sources as anchored `--exclude` patterns, placed before user filter rules). Always resolve paths with `realpath(3)` (`SandboxProfile.resolved`).
   - Extra permissions exist only for paths the user chooses in a job (`AdvancedOptions.readablePaths`, `writableFiles`, `writableDirectories`): list files and reference directory (read); `--log-file`, `--write-batch` file and `.sh` (write file); outside `--backup-dir` and `--link-dest` reference (write folder). Paths written inside the source are refused (`Problem.writesInsideSource`). Never widen these to whole parent folders.
   - List files are never read by rsync from protected folders: `RsyncEngine.stageListFiles` passes a private 0700 copy.
5. **Single Argument Source:** every rsync argument comes from `RsyncCommand`; absolute paths always follow `--`. Default local copy: `-rltDhX --info=progress2 --partial`. exFAT/FAT/NTFS targets never receive `-p/-o/-g/-A`; FAT gets `--modify-window=1`.
6. **Position-Anchored Output Classification:** `RsyncOutcome` matches error classes only at rsync's message position (`messageBody`) or as the trailing errno text (`endsWithErrno`), never as a free substring, so file names cannot fake an error class.
7. **Engine Independence:** jobs carry a `JobKind`; engines implement `TransferEngine` and are registered in `TransferEngines.engine(for:)`. Queue, persistence and UI must not depend on rsync specifics.
8. **Complete Trilingual Localization (`tr`, `en`, `ro`), Mandatory 1:1 Exact Translation & Dedicated File per Language:**
   - Every user-facing string is an `LKey` with authentic, non-fallback entries in `Resources/{tr,en,ro}.lproj/Localizable.strings`; Finder-visible plist names and the service title live in `InfoPlist.strings` and `ServicesMenu.strings` per language.
   - Format specifiers and argument counts match 1:1. Missing keys, extra keys, English left in non-English tables and hard-coded view text fail `swift test`.
   - **Restart Standard:** changing the language shows `restartWarningTitle` / `restartMenuBarNotice` and writes `AppleLanguages`.
9. **Backward-Compatible Persistence:** `TransferJob`, `CopyOptions` and `JobResult` decode with defaults for missing or unknown values; a corrupt `jobs.json` is set aside, never silently deleted.
10. **Cryptographic Release Verification:** every release `.dmg` carries an Ed25519 signature (`.dmg.sig`, key in the login keychain as `com.babadogantech.copiator.update-signing`, public key `CopiatorUpdatePublicEDKey`) and `SHA256SUMS.txt`.
11. **OWASP Agentic Security (ASI) & Subprocess Shielding:** see `rules/owasp_agentic_security.md`; untrusted inputs are file names, rsync output and downloaded releases.
12. **Verified Sleep Prevention:** a running job holds a `SleepGuard` assertion (`caffeinate -i`, optional `-d`) that is verified in the system's assertion list and released on finish, pause, failure and quit; each transition is logged and announced. Never claim sleep is prevented without verification.
13. **Snapshot Pruning Safety:** only `SnapshotStore.prune` deletes data, and only real directories directly inside the snapshot root whose names parse exactly as `yyyy-MM-dd-HHmmss`. It never removes the snapshot just created, partial snapshots, symlinks or any other item, runs only after a fully successful run with at least one retention rule, and retention must be confirmed in the UI when it is set or changed.
14. **No Orphaned Engine:** every child process goes through `CommandRunner`, which registers it with `ChildProcessGuard`. The crash handler may only call async-signal-safe functions (`kill`, `raise`). Orphan reaping at launch kills a process only if its PID, exact start time and launchd parent all match the record.
15. **User-Rejected Scope:** scheduled (time-based) jobs and remote (SSH) jobs are rejected (`context/user_rejected_spec.md`); jobs start manually, from the Finder service, from Shortcuts or when the destination disk is connected.
16. **Routines Only Add:** rule-based jobs (`CopyOptions.rules`) never produce `--delete`; `Routine.jobOptions(for:)` and `RuleSelection.prepare` both force it off, and the rule scanner never enters protected personal folders when sandboxed. Rules are evaluated by the app, never translated into rsync glob patterns.
17. **Never Overwrite Silently by Default:** `ConflictPolicy.ask` is the default for every job and routine. A run that finds same-name files without a decision must stop with `.awaitingDecision` before rsync writes anything; "skip" and "keep both" paths must be excluded from the main transfer (and `--from0` must precede any `*-from` option). Keep-both never touches the existing destination file. An item of another type under the same name (file ↔ folder ↔ link) is a conflict too, because rsync would delete it; for an incoming folder Keep Both renames the existing item, never deletes it. Destination checks use `lstat` and never follow links, also in parent folders.
18. **Literal rsync Patterns:** a path used as an rsync filter pattern goes through `RsyncCommand.escapePattern` once, as a whole (root prefix included). It escapes `*`, `?`, `[` and `\` only when the pattern contains `*`, `?` or `[`; rsync compares other patterns literally.
19. **Bounded User Input:** user-entered rule values never run unbounded: regexes stop at `RuleEvaluator.regexStepBudget` (reported, never treated as "no match" silently), numbers are clamped before `Int` conversion, and media sizes are range-checked.
20. **Placement Stays Inside:** placement templates never produce a path outside the destination: every rendered component goes through `RoutePlacement.component` and `PlacementStaging.build` refuses targets with "." or "..". Staging reads the source only; links in the staging tree point to source files and are followed with `--copy-unsafe-links`, so links that escape a package are never staged.
21. **Sync Never Deletes:** `SyncEngine` only copies missing files and decided differences, each direction as a sandboxed `RsyncEngine` job with `deleteExtraneous` off; a file deleted on one side comes back from the other.
22. **On-Device AI Only, Suggestions Only:** `Suggestions` uses `SystemLanguageModel.default`, a local model server chosen in Settings, or all of them in the automatic order (`FallbackSuggestionModel`: an unreachable, failing or invalid model is skipped silently, never an error dialog) (Ollama on 127.0.0.1:11434, LM Studio on 127.0.0.1:1234; `LocalModelServer`). Never Private Cloud Compute, Ollama cloud models (`remote_host`, `…:cloud`) or any other network service; local requests use no proxy, follow no redirects and accept only 127.0.0.1 responses; answers are validated against the candidates and the token list, and nothing is applied without the user's action. The AI only reorders suggestions, never picks a folder or a name by itself, and every AI control shows `AILanguageWarning` while Apple Intelligence is the provider (that model works best in English). AI path suggestions (a new folder for a file, a subfolder template) pass `PlacementResolution.clean` / `cleanFolderTemplate` and can never point outside the destination. Every AI call is time-limited and ends in `SuggestionResult` (`value`, `noSuggestion`, `unavailable`); an AI failure never throws into the app or crashes it, and the UI says when the suggestion engine is unavailable. Templates must reproduce the destination's examples (derived by rule first); prompts never contain an answer a model could copy. In Automatic mode Apple's existing-folder picks are cross-checked by the next ready model, whose decision wins on disagreement.
23. **Chosen Folders Stay Inside:** in suggested placement (`RoutePlacement.askFolder`) a file is copied only into a folder the user chose (or remembered and still present); chosen and remembered folders pass through `PlacementResolution.clean` and again through `RoutePlacement.target`, so a crafted job file cannot place files outside the destination. The job waits as "Needs decision" before anything is copied.

---

## 2. TencentDB Agent Memory Four-Tier Pyramid (L0–L3)

| Tier | Category | Scope in Copiator | Storage / Artifact |
| :--- | :--- | :--- | :--- |
| **L0** | **Conversation / Execution Logs** | Raw turns, `swift test` output, rsync traces | Session transcripts & temporary build outputs |
| **L1** | **Atom (Atomic Parameters)** | `DiskSpace.reserve = 1 GiB` (≤ 2 % of volume), `DiskSpaceGuard.floor = 512 MiB`, `killGracePeriod = 2 s`, `drainGracePeriod = 2 s`, `progressInterval = 0.25 s`, `maxLogEntries = 500`, `maxHistoryEntries = 100`, `maxLoggedDifferences = 100`, `maxOutputBytes = 512 MiB`, unplug grace for recently failed jobs = 30 s | `DiskSpace.swift`, `CommandRunner.swift`, `RsyncEngine.swift`, `Job.swift` |
| **L2** | **Scenario (Engine & Runtime States)** | `AppModel` (`EngineStatus`, `JobStatus`, `runningJobID`, `OperationState`, `UpdateState`), `AppSettings` (`UserDefaults`), `jobs.json` | `context/symbolic_memory_graph.md`, `context/domain_wiki.md` |
| **L3** | **Persona (Governance & Invariants)** | Constitution, security redlines, SDD gates, localization rules | `AGENTS.md`, `rules/`, `context/user_rejected_spec.md` |

---

## 3. Mandatory Agent Workflow

1. **Constitutional Alignment:** Read this file before modifying any source file, script, or resource.
2. **Context & Symbol Lookup:** Consult `context/domain_wiki.md`, `context/code_graph_wiki.md`, `context/symbolic_memory_graph.md`, and `context/reflexion_memory_log.md` before changing argument generation, output parsing, sandboxing, queue flows or persistence.
3. **Rule Verification:** Check `rules/about_rules.md`, `rules/math_rules.md`, `rules/ui_rules.md`, and `rules/github_spec_kit.md`.
4. **Skill Execution:** Use `skills/sentinel_test_skill.md` to validate changes with `swift test` before completing any task; `skills/engine_maintenance_skill.md` when touching `Vendor/rsync`; `skills/snapshot_audit_skill.md` when touching persisted data or `Info.plist`.
