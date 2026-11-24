# Code-Graph Wiki — Indexed Symbols & Impact Map

> **Memory Category:** TencentDB Code-Graph Memory Asset
> **Scope:** Module boundaries, key types, call hierarchy, and cross-file modification impact map.
> **Generated from:** `graphify-out/GRAPH_REPORT.md` and `graphify-out/graph.json` (graphifyy 0.9.101, local tree-sitter AST, `--code-only`, no LLM backend). Sections 3–4 are hand-maintained and checked against the graph.
> **Built at commit:** `dc31f1c` (2026-11-24), refreshed with `graphify update .` and `cluster-only --no-label`; the git hooks rebuild the graph after each commit.
> **Regenerate:** `GRAPHIFY_NO_TIPS=1 GRAPHIFY_QUERY_LOG_DISABLE=1 GRAPHIFY_BACKEND=off graphify extract . --code-only`, then `GRAPHIFY_BACKEND=off graphify cluster-only . --no-label`, then update sections 1–2 from the new report. `graphify-out/` is git-ignored.

---

## 1. Graph Summary

- **Corpus:** 6,185 nodes, 16,508 edges, 208 Leiden communities (21 thin ones omitted from the report) after the 2026-11-24 refresh. By kind: 5,323 code nodes, plus 443 rationale, 338 concept, 73 document, 7 paper and 1 image node that an earlier full build of the Markdown files left in `graph.json`; `graphify update .` refreshes the code nodes only. New types since the 2026-11-07 refresh include `RoutineRouteSection`, `JobSaveQueue`, `JobCommandPreview`, `DiagnosticMasker.KnownPath`, `RoutineScan` and `SpotlightLookup`.
- **Edge provenance:** 83% `EXTRACTED`, 17% `INFERRED` (2,817 edges, average confidence 0.86), 0% `AMBIGUOUS`.
- **Edge relations:** `references` 5,610 · `calls` 4,764 · `method` 1,790 · `case_of` 1,765 · `contains` 849 · `implements` 657 · `imports` 532 · `conceptually_related_to` 299 · `semantically_similar_to` 74 · `rationale_for` 64 · `inherits` 34 · `defines` 27.
- **Module dependencies:** `Copiator` → `CopiatorCore`; `CopiatorCoreTests` → `CopiatorCore`; `CopiatorAppTests` → `Copiator`, `CopiatorCore`. `CopiatorCore` imports no app target. Import cycles: none.
- **Not indexed:** `Vendor/` (the bundled rsync), `.strings` tables, `Info.plist`, `.claude/` and build outputs (see `.graphifyignore`). Markdown files are not re-read by `graphify update .`; their nodes date from the earlier full build.
- **Known gaps:**
  - `AIEvaluationTests` defines its own `enum Task`, so some `INFERRED` edges link Swift concurrency `Task { … }` calls in app views to that test enum. Treat any `Task` edge that crosses into `AIEvaluationTests.swift` as a name collision.
  - The `LKey` cases (about 1,600 nodes) look isolated because the `.strings` tables are not indexed; use `LocalizationTests` and the three tables for key usage.

## 2. Hub Nodes (most connected)

| Rank | Node | Edges | Why it is a hub |
| :--- | :--- | ---: | :--- |
| 1 | `LKey` | 1,274 | Every user-facing string; a new case needs all three `.strings` tables |
| 2 | `AppModel` | 355 | App state machine: queue, engine, decisions, routines, archive health, notifications, background saves |
| 3 | `TransferJob` | 303 | The job model: source, destination, options, status, result, history, pending decisions |
| 4 | `CopyOptions` | 194 | Every per-job option; tolerant decoding keeps old `jobs.json` files readable |
| 5 | `AppSettings` | 141 | `UserDefaults`-backed preferences and the localized text lookup (`t()`) |
| 6 | `Fixture` | 134 | `CopiatorAppTests` helper: an `AppModel` with its own folder, `UserDefaults` suite and the real rsync |
| 7 | `Workspace` | 122 | `CopiatorCoreTests` helper: a temporary folder with write, read and link helpers |
| 8 | `CopiatorCore` | 118 | Module imported by the app and both test targets |
| 9 | `Routine` | 109 | Copy and sync routines with their routes, rules and placement |
| 10 | `RsyncEngine` | 96 | Preflight, snapshots, sandbox, run, verify and compare |

Before changing a hub, run `graphify affected "<node>"` to see what depends on it.

---

## 3. Module & File Index

### Target: `CopiatorCore` (`Sources/CopiatorCore/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `CommandRunner.swift` | `ProcessResult`, `EngineError`, `CommandRunner`, `ProcessBox`, `RunState` | Subprocess execution, `\r`/`\n` record streaming (`onRecord`), tail-only stdout (`retainStdout: false`), timeout, SIGTERM + 2 s SIGKILL, bounded drain after exit, output cap |
| `Sandbox.swift` | `SandboxProfile` (`forTransfer`, `protectedPaths`, `resolved`, `profileText`), `CommandRunner.sandboxed` | SBPL generation, realpath resolution, personal-data protection |
| `RsyncCommand.swift` | `RsyncCommand` (`transfer`, `verify`, `Environment`, `systemExclusions`, `escapePattern`) | The single source of rsync arguments |
| `RsyncProgress.swift` | `TransferProgress` (`currentItem`, `fileFraction`, `filesListed`, `isListing`), `RsyncProgressParser` | `--info=progress2`/`progress1` parsing, units |
| `AdvancedOptions.swift` | `AdvancedOptions`, `ExcludePreset`, `SymlinkMode`, `DeleteTiming`, `AppendMode`, `ReferenceMode`, `BatchMode`, `ProgressDetail`, `Problem` | Sandbox-compatible rsync options, validation, extra sandbox paths, `--stop-at` format |
| `RsyncOutputCollector.swift` | `RsyncOutputCollector` | Output records → progress, names, list counter, batched change lines, statistics |
| `PowerAdvisor.swift` | `PowerSnapshot`, `PowerAdvice`, `PowerAdvisor`, `SleepGuard` | Power source/battery/Low Power Mode, advice rules, verified sleep assertions |
| `RsyncOutcome.swift` | `RsyncOutcome` (`classify`, `errorLines`, `messageBody`, `endsWithErrno`) | Exit code + stderr → `JobResult` |
| `ItemizeParser.swift` | `DiffEntry`, `ItemizeParser` (`Format`: rsync 3.x 11 columns, openrsync 9 columns) | `-i` parsing, `\#ooo` unescaping |
| `Engine.swift` | `EngineInfo`, `EngineLocator`, `EngineUpdateResult`, `EngineUpdater` | Candidates, version/capability parsing, choice, updater wrapper |
| `TransferEngine.swift` | `TransferEngine`, `TransferEvent`, `EngineContext` (`scratchDirectory`), `VerifyReport`, `TransferEngines` | Engine-independent contract and registry |
| `RsyncEngine.swift` | `RsyncEngine` (`run`, `verify`, `compare`, `verifyAfterCopy`, `finishSnapshot`), `ProgressThrottle` | Preflight, snapshots, sandbox, disk guard, run, classify, quarantine, verify after copy |
| `Job.swift` | `JobKind`, `CopyMode`, `VerifyAfterCopy`, `CopyOptions` (`snapshots`, `verifyAfterCopy`, `runWhenConnected`, `problems`), `JobStatus` (incl. `verifying`), `JobResultKind` (incl. `verificationFailed`), `JobResult` (`snapshot`, `differenceCount`), `JobRun`, `JobLogEntry`, `TransferJob` (`history`, `suspendedForDisk`, `uses(volume:)`), `JobValidation` | Codable job model with tolerant decoding |
| `DiagnosticMasker.swift` | `DiagnosticMasker` (`path`, `name`, `text(_:knownPaths:)`, `prepare` → `KnownPath`, `text(_:known:)`, `argument`) | Salted masking of paths, names and user names for the diagnostic report |
| `JobStore.swift` | `JobStore`, `JobSaveQueue` (`saveSoon`, `flush`), `JobQueue` (`next(pathsAvailable:)`, `isWaitingForDisk`, `canEdit`, `finish` → history) | Persistence, background save order and pure queue rules |
| `DiskSpace.swift` | `DiskSpace`, `InsufficientSpaceError`, `DiskSpaceGuard`, `FileSystemKind`, `OwnerAccess`, `Int64.saturatingAdding` | Space checks, file-system detection |
| `Quarantine.swift` | `Quarantine` | Quarantine propagation |
| `SleepAssertion.swift` | `SleepAssertion` | IOPMAssertion |
| `OpenSafety.swift` | `OpenSafety` | Deceptive character detection and visible names |
| `AppUpdate.swift` | `AppRelease`, `AppUpdateChecker`, `UpdateSignature`, `UpdateChecksums` | Release check and verification |
| `Localization.swift` | `AppLanguage`, `StringTable` (`resultMessage`, `logText`), `LKey` | Localization engine and keys |
| `Snapshots.swift` | `SnapshotOptions`, `SnapshotStore` (`prepare`, `plan`, `apply`, `finalize`, `updateLatestLink`, `retained`, `prune`, `removeTree`) | Dated snapshot folders, `.partial` resume, `Latest` link, retention and pruning |
| `Rules.swift` | `RuleMatch`, `RuleAttribute` (basic/advanced, `valueKind`, `operators`, `units`), `RuleOperator` (`input(for:)`), `RuleUnit`, `FileKind`, `RuleCondition` (`starting`), `RuleGroup` (`problems`, `allConditions`, `maxDepth`) | Finder-style rule model |
| `RuleEvaluation.swift` | `RuleItem` (lazy metadata), `MediaInfo` (`pixels`), `RuleEvaluator` (`regexStepBudget`, `RunawayRegex`, `runawayPattern`), `RuleScanner` (async), `SpotlightLookup` (per-scan lazy cache), `Spotlight` | Evaluation, metadata reading, source scanning |
| `Placement.swift` | `RoutePlacement` (`target(for:date:destination:folder:)`, `renderName`, `component`, `folderPresets`, `nameFixes`, `askFolder`, `learnedFolders`), `NameFix` (`pieces`, `apply`, `presets`), `PlacementDateSource`, `PlacementToken` (`addTarget`), `PlacementStaging`, `PlacementDate`, `ExtendedAttributes` | Folder and name templates, naming modes, link staging tree |
| `PlacementDecisions.swift` | `PlacementReport`, `PlacementResolution` (`clean`), `PlacementMemory` (`key`), `PlacementQuestions` (`plan`, `DecisionNeeded`) | Suggested placement: ask, remember, resolve |
| `ContentReader.swift` | `ContentReader` (`text`, `contains`, `fold`), `TextDate` (`find`) | PDF and plain-text reading, dates in text |
| `SourceTrash.swift` | `SourceTrash` (`pairs`, `moveVerified`, `archivedFiles`, `move`, `systemTrash`) | Verified move to the Trash, clean-up of archived sources |
| `Sync.swift` | `SyncPlan`, `SyncPlanner`, `SyncEngine` | Two-way sync without deletions |
| `Suggestions.swift` | `SuggestionModel`, `OnDeviceSuggestionModel`, `Suggestions` (`rankFolders`, `placeFile`/`parsePlacement`/`FilePlacement`, `nameTemplate`, `cleanTemplate`, `folderTemplate`, `cleanFolderTemplate`, `exampleNames`, `exampleFolders`) | AI suggestions (rank, place, name and folder templates) |
| `AIPrerequisites.swift` | `AIPrerequisites` (`Problem`, `Check`, `appleProblem`, `checkApple`, `checkServer`, `testTimeout`) | Prerequisite checks when AI suggestions are turned on |
| `TemplateInference.swift` | `TemplateInference` (`nameTemplate`, `folderTemplate`, `date`, `tokens`, `symbols`, `infer`) | Rule-based name and subfolder templates from examples |
| `LocalModels.swift` | `SuggestionProvider` (`order`), `FallbackSuggestionModel` (`members`, `lastSource`), `LocalModelServer` (`models`, `request`, `ollamaModels`, `openAIModels`, `isCloud`, `withoutThinking`), `LocalServerSuggestionModel` | Ollama and LM Studio on 127.0.0.1 only, cloud models filtered |
| `ArchiveTools.swift` | `DestinationIndex`, `DestinationSummary`, `FolderSuggester` | Same contents at the destination, destination overview, folder suggestions |
| `BackupFreshness.swift` | `BackupFreshness` (`Stale`, `choices`, `lastSuccess`, `stale`) | Jobs and routines without a recent successful run, for the old backup reminder |
| `SnapshotRestore.swift` | `SnapshotRestore` (`Snapshot`, `Item`, `Version`, `snapshots`, `contentRoot`, `items`, `versions`, `originalFolder`, `restoreJob`) | Snapshot browsing, file versions deduplicated by inode, restore as an ordinary copy job |
| `ArchiveIntegrity.swift` | `ArchiveIntegrity` (`manifestName`, `Entry`, `Manifest`, `Report`, `manifest`, `check`, `regularFiles`, `hash`) | Hidden integrity list at the destination, silent-corruption detection, SHA-256 hashing |
| `IntegrityRepair.swift` | `ArchiveIntegrity.RepairReport`, `repair`, `repairSources`, `isInside`, `candidateFiles`, `write`, `realPath`, `modifiedTime` | Repair of damaged files in place from copies with the recorded digest |
| `DiskEject.swift` | `DiskEject` (`volume`, `isEjectable`, `siblingVolumes`, `isBusy`, `eject`) | Eject the destination disk when done: ejectable volume, same-disk volumes, busy check, unmount and eject |
| `DuplicateFinder.swift` | `DuplicateFinder` (`Group`, `groups`, `trashExtras`, `isSnapshotFolder`) | Identical files at the destination, re-verified move of extras to the Trash |
| `RoutineTransfer.swift` | `RoutineTransfer` (`format`, `version`, `maxSize`, `Failure`, `Missing`, `export`, `read`, `missingFolders`, `remap`) | Routine export/import file, new identities, numbered names, missing-folder remapping |
| `Routines.swift` | `Routine` (`jobOptions(for:)`, `problems`), `RoutineRoute`, `RoutineStore`, `RuleSelection` | Routine model, persistence, `--files-from` list preparation |
| `Conflicts.swift` | `ConflictPolicy`, `ConflictDecision`, `FileConflict` (`incomingFolder`), `ConflictReport`, `ConflictResolution`, `ConflictDetector` (`conflicts(in:format:existsAtDestination:)`), `ConflictCollector` (`lstat` without following links) | Same-name file detection, decisions, numbered names |
| `ChildProcessGuard.swift` | `ChildProcessGuard` (`register`, `unregister`, `configure`, `installCrashHandlers`, `reapOrphans`, `Record`) | Signal-safe child table, crash/termination handlers, orphan reaping at launch |

### Target: `Copiator` (`Sources/Copiator/`)

| File | Primary Symbols |
| :--- | :--- |
| `CopiatorApp.swift` | `CopiatorApp`, `AppDelegate`, `AppCommands` |
| `AppModel.swift` | `AppModel`, `SidebarItem` (`home`, filter, routine), `EngineStatus`, `UpdateState`, `AppUpdateState`, `OperationState`, `JobFilter`, `NewJobRequest`, `VerifyPresentation`, `AppLinks`, `AppInfo`, `WindowID`, `SnapshotBrowserRequest`, `IntegrityRequest`, `IntegrityProgress`, `IntegrityOutcome`, `CancelFlag`, `DuplicatesRequest`, `RoutineImportRequest`, `handleNotice`, `backUpNow`, `repairCorrupted`, `ejectIdleDisks`, `save` / `flushSaves` (background writes), `hasRemovableJobs`, `freeSpaceOffMain` |
| `Diagnostics.swift` | `DiagnosticPresentation`, `AppModel.diagnosticReport` (known paths and the date formatter prepared once), `DiagnosticSheet` | Masked plain-text report, previewed and saved only where the user chooses |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `KeyboardShortcutData`, `ShortcutAction` |
| `FinderServices.swift` | `FinderServices.backUp` |
| `Intents.swift` | `IntentTarget`, `JobEntity`, `JobEntityQuery`, `RunJobIntent`, `PauseAllJobsIntent`, `ResumeAllJobsIntent`, `CopiatorShortcuts`, `AppModel.runFromShortcut` |
| `StatusItems.swift` | `MenuBarContent`, `MenuBarLabel`, `DockProgress`, `VolumeWatcher` |
| `PowerAdvice+UI.swift` | `PowerAdvice` extension | Localized title, message and symbol for each power advice |
| `Notices.swift` | `NoticeAction` (`category`, `userInfo`, `init?(category:userInfo:)`, `categories`), `NoticeHandler` | Notification buttons and the notification center delegate |
| `Views/ConflictViews.swift` | `ConflictSheet`, `ConflictPolicyPicker` |
| `Views/PlacementDecisionViews.swift` | `PlacementDecisionView` (shown inside `ConflictSheet` when `pendingPlacements` is set) |
| `Views/PlacementViews.swift` | `PlacementEditor`, `AITemplateSuggestionRow`, `AppSettings.describe(_ placement:)` |
| `Views/ArchiveViews.swift` | `RoutinePickerSheet`, `DestinationSummarySheet`, `AILanguageWarning`, `FolderSuggestionButton`, `CleanupSheet` |
| `Views/SnapshotViews.swift` | `SnapshotBrowserSheet` | Snapshot list, folder browser, file versions, restore to the original place or elsewhere |
| `Views/ArchiveHealthViews.swift` | `IntegritySheet`, `DuplicatesSheet` | Integrity check with progress, stop and check-on-connect; duplicate groups with the kept copy and confirmed move to the Trash |
| `Views/RoutineViews.swift` | `RuleConditionRow`, `RuleGroupEditor`, `FolderChooserRow`, `RoutineEditorSheet`, `RoutineRouteSection`, `RoutineDetailView`, `AppSettings.describe(_:)` |
| `Views/JobOptionsSections.swift` | `VerifyAfterCopyPicker`, `SnapshotSection`, `CountField`, `AutomationSection`, `ExcludePresetsSection`, `PreviewSheet`, `JobHistoryList` |
| `Views/AdvancedOptionsForm.swift` | `AdvancedOptionsSections`, `CommandPreview`, `PowerStatusBanner`, `SandboxLimitsSection` | Advanced rsync options form, the copyable `rsync …` command, the power banner and the sandbox limits note |
| `Views/ContentView.swift` | `ContentView`, `OverlayTiming`, `ProgressOverlay`, `ToastView` |
| `Views/JobListView.swift` | `SidebarView`, `JobListView` (list-wide menu state computed once per redraw), `JobRow`, `StatusBadge`, `JobCommandPreview` (`Equatable`: the rsync command is rebuilt only when the job's paths, options or run count change), `JobDetailView` |
| `Views/NewJobSheet.swift` | `NewJobSheet`, `VerifyResultSheet`, `WelcomeView`, `EngineStatusView` |
| `Views/SettingsView.swift`, `AboutView.swift`, `LicenseViewerSheet.swift` | Settings tabs, About, `LicenseDocument` |

## 4. Impact Map

| Change | Also update |
| :--- | :--- |
| New rsync flag | `AdvancedOptions` (+ tolerant decoding, validation), `RsyncCommand.advancedFlags`/`verify`, `unsupportedByOpenrsync`, `AdvancedOptionsSections`, three tables, `AdvancedOptionsTests`, `docs/rsync-possible-in-sandbox.md` |
| New result kind | `JobResultKind`, `RsyncOutcome`, `StringTable.resultMessage`, three `Localizable.strings`, `LocalizationTests` |
| New job field | `TransferJob` coding keys + tolerant decoding, `JobModelTests.decodesMinimalAndForwardJobs`, `snapshot_audit_skill.md` |
| New engine | `JobKind` case, `TransferEngine` implementation, `TransferEngines.engine(for:)`, integration tests |
| New UI string | `LKey` + three tables |
| New App Intent or Siri phrase | `Intents.swift`, `Localizable.strings` keys for titles, `AppShortcuts.strings` in all three languages, `appShortcutPhrasesAreLocalized`, `verify_bundle.sh` action list |
| New decision type that pauses a job | `TransferEvent` case, `TransferJob` field + coding key, `isAwaitingDecision`, `JobQueue.apply`/`finish`, `AppModel.resume`/`notify`, a view inside `ConflictSheet`, switches in `SyncEngine` and `AppModel.apply(_:to:)` |
| New job status | `JobStatus` (+ `isActive`), `JobStatus.titleKey`, progress bar and badge switches in `JobListView`, `JobFilter` |
| New file Copiator writes at a destination | Exclude it in `RsyncCommand.exclusions` (as `/.copiator-integrity.json` is) so `--delete` keeps it and verification does not report it, skip it in `ArchiveIntegrity.skippedNames` and `DuplicateFinder`, update `RsyncCommandTests.systemExcludes` and `AdvancedOptionsTests` |
| New notification button | `NoticeAction` case + category + `userInfo` round trip, `NoticeAction.categories`, `AppModel.handleNotice` (validate the item), LKey in three tables, `NoticeAndEjectAppTests` |
| New thing that keeps a disk in use | `DiskEject.isBusy` (jobs or `checking` paths) and a call to `AppModel.ejectIdleDisks` when it ends |
| New routine field | `Routine` coding keys + tolerant decoding, `RoutineTransfer.read` (reset or keep on import), `RoutineTransferTests` round trip |
| Code or a test that reads `jobs.json` right after an action | Call `AppModel.flushSaves()` first: `save()` writes in the background through `JobSaveQueue` (`waitUntilIdle` and `prepareForTermination` already flush) |
| New state shown in every row of a list (menu item, badge) | Compute it once in the list's `body` and pass it to the rows; a per-row scan of `model.jobs` costs the square of the job count (`JobListView.contextMenu`) |
| New input to the rsync command preview | Add it to `JobCommandPreview.==`, or the details panel keeps showing the old command |
| New section in a long `Form` | Keep rows direct children of a `Section` and check the PNG (`COPIATOR_SNAPSHOT_DIR`): `.equatable()` or a `DisclosureGroup` around rows breaks the grouped layout (`RoutineRouteSection`) |
| Directory walk with `FileManager.enumerator` | Call `skipDescendants()` only for directories: on a file it skips the rest of the enclosing folder |
