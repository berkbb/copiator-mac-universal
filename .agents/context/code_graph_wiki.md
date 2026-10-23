# Code-Graph Wiki — Indexed Symbols & Impact Map

> **Memory Category:** TencentDB Code-Graph Memory Asset
> **Scope:** Module boundaries, key types, call hierarchy, and cross-file modification impact map.

---

## 1. Module & File Index

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
| `JobStore.swift` | `JobStore`, `JobQueue` (`next(pathsAvailable:)`, `isWaitingForDisk`, `canEdit`, `finish` → history) | Persistence and pure queue rules |
| `DiskSpace.swift` | `DiskSpace`, `InsufficientSpaceError`, `DiskSpaceGuard`, `FileSystemKind`, `OwnerAccess`, `Int64.saturatingAdding` | Space checks, file-system detection |
| `Quarantine.swift` | `Quarantine` | Quarantine propagation |
| `SleepAssertion.swift` | `SleepAssertion` | IOPMAssertion |
| `OpenSafety.swift` | `OpenSafety` | Deceptive character detection and visible names |
| `AppUpdate.swift` | `AppRelease`, `AppUpdateChecker`, `UpdateSignature`, `UpdateChecksums` | Release check and verification |
| `Localization.swift` | `AppLanguage`, `StringTable` (`resultMessage`, `logText`), `LKey` | Localization engine and keys |
| `Snapshots.swift` | `SnapshotOptions`, `SnapshotStore` (`prepare`, `plan`, `apply`, `finalize`, `updateLatestLink`, `retained`, `prune`, `removeTree`) | Dated snapshot folders, `.partial` resume, `Latest` link, retention and pruning |
| `Rules.swift` | `RuleMatch`, `RuleAttribute` (basic/advanced, `valueKind`, `operators`, `units`), `RuleOperator` (`input(for:)`), `RuleUnit`, `FileKind`, `RuleCondition` (`starting`), `RuleGroup` (`problems`, `allConditions`, `maxDepth`) | Finder-style rule model |
| `RuleEvaluation.swift` | `RuleItem` (lazy metadata), `MediaInfo` (`pixels`), `RuleEvaluator` (`regexStepBudget`, `RunawayRegex`, `runawayPattern`), `RuleScanner` (async), `Spotlight` | Evaluation, metadata reading, source scanning |
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
| `DuplicateFinder.swift` | `DuplicateFinder` (`Group`, `groups`, `trashExtras`, `isSnapshotFolder`) | Identical files at the destination, re-verified move of extras to the Trash |
| `RoutineTransfer.swift` | `RoutineTransfer` (`format`, `version`, `maxSize`, `Failure`, `Missing`, `export`, `read`, `missingFolders`, `remap`) | Routine export/import file, new identities, numbered names, missing-folder remapping |
| `Routines.swift` | `Routine` (`jobOptions(for:)`, `problems`), `RoutineRoute`, `RoutineStore`, `RuleSelection` | Routine model, persistence, `--files-from` list preparation |
| `Conflicts.swift` | `ConflictPolicy`, `ConflictDecision`, `FileConflict` (`incomingFolder`), `ConflictReport`, `ConflictResolution`, `ConflictDetector` (`conflicts(in:format:existsAtDestination:)`), `ConflictCollector` (`lstat` without following links) | Same-name file detection, decisions, numbered names |
| `ChildProcessGuard.swift` | `ChildProcessGuard` (`register`, `unregister`, `configure`, `installCrashHandlers`, `reapOrphans`, `Record`) | Signal-safe child table, crash/termination handlers, orphan reaping at launch |

### Target: `Copiator` (`Sources/Copiator/`)

| File | Primary Symbols |
| :--- | :--- |
| `CopiatorApp.swift` | `CopiatorApp`, `AppDelegate`, `AppCommands` |
| `AppModel.swift` | `AppModel`, `EngineStatus`, `UpdateState`, `AppUpdateState`, `OperationState`, `JobFilter`, `NewJobRequest`, `VerifyPresentation`, `AppLinks`, `AppInfo`, `WindowID`, `SnapshotBrowserRequest`, `IntegrityRequest`, `IntegrityProgress`, `IntegrityOutcome`, `CancelFlag`, `DuplicatesRequest`, `RoutineImportRequest` |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `KeyboardShortcutData`, `ShortcutAction` |
| `FinderServices.swift` | `FinderServices.backUp` |
| `Intents.swift` | `IntentTarget`, `JobEntity`, `JobEntityQuery`, `RunJobIntent`, `PauseAllJobsIntent`, `ResumeAllJobsIntent`, `CopiatorShortcuts`, `AppModel.runFromShortcut` |
| `StatusItems.swift` | `MenuBarContent`, `MenuBarLabel`, `DockProgress`, `VolumeWatcher` |
| `Views/ConflictViews.swift` | `ConflictSheet`, `ConflictPolicyPicker` |
| `Views/PlacementDecisionViews.swift` | `PlacementDecisionView` (shown inside `ConflictSheet` when `pendingPlacements` is set) |
| `Views/PlacementViews.swift` | `PlacementEditor`, `AITemplateSuggestionRow`, `AppSettings.describe(_ placement:)` |
| `Views/ArchiveViews.swift` | `RoutinePickerSheet`, `DestinationSummarySheet`, `AILanguageWarning`, `FolderSuggestionButton`, `CleanupSheet` |
| `Views/SnapshotViews.swift` | `SnapshotBrowserSheet` | Snapshot list, folder browser, file versions, restore to the original place or elsewhere |
| `Views/ArchiveHealthViews.swift` | `IntegritySheet`, `DuplicatesSheet` | Integrity check with progress, stop and check-on-connect; duplicate groups with the kept copy and confirmed move to the Trash |
| `Views/RoutineViews.swift` | `RuleConditionRow`, `RuleGroupEditor`, `FolderChooserRow`, `RoutineEditorSheet`, `RoutineDetailView`, `AppSettings.describe(_:)` |
| `Views/JobOptionsSections.swift` | `VerifyAfterCopyPicker`, `SnapshotSection`, `CountField`, `AutomationSection`, `ExcludePresetsSection`, `PreviewSheet`, `JobHistoryList` |
| `Views/ContentView.swift` | `ContentView`, `OverlayTiming`, `ProgressOverlay`, `ToastView` |
| `Views/JobListView.swift` | `SidebarView`, `JobListView`, `JobRow`, `StatusBadge`, `JobDetailView` |
| `Views/NewJobSheet.swift` | `NewJobSheet`, `VerifyResultSheet`, `WelcomeView`, `EngineStatusView` |
| `Views/SettingsView.swift`, `AboutView.swift`, `LicenseViewerSheet.swift` | Settings tabs, About, `LicenseDocument` |

## 2. Impact Map

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
| New routine field | `Routine` coding keys + tolerant decoding, `RoutineTransfer.read` (reset or keep on import), `RoutineTransferTests` round trip |
| Directory walk with `FileManager.enumerator` | Call `skipDescendants()` only for directories: on a file it skips the rest of the enclosing folder |
