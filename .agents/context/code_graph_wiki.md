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
| `TransferEngine.swift` | `TransferEngine`, `TransferEvent`, `EngineContext`, `VerifyReport`, `TransferEngines` | Engine-independent contract and registry |
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
| `Rules.swift` | `RuleMatch`, `RuleAttribute`, `RuleOperator`, `FileKind`, `RuleCondition`, `RuleGroup` (`problems`, `maxDepth`), `RuleItem`, `RuleEvaluator`, `RuleScanner` | Finder-style rules, evaluation and source scanning |
| `Routines.swift` | `Routine` (`jobOptions(for:)`, `problems`), `RoutineRoute`, `RoutineStore`, `RuleSelection` | Routine model, persistence, `--files-from` list preparation |
| `ChildProcessGuard.swift` | `ChildProcessGuard` (`register`, `unregister`, `configure`, `installCrashHandlers`, `reapOrphans`, `Record`) | Signal-safe child table, crash/termination handlers, orphan reaping at launch |

### Target: `Copiator` (`Sources/Copiator/`)

| File | Primary Symbols |
| :--- | :--- |
| `CopiatorApp.swift` | `CopiatorApp`, `AppDelegate`, `AppCommands` |
| `AppModel.swift` | `AppModel`, `EngineStatus`, `UpdateState`, `AppUpdateState`, `OperationState`, `JobFilter`, `NewJobRequest`, `VerifyPresentation`, `AppLinks`, `AppInfo`, `WindowID` |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `KeyboardShortcutData`, `ShortcutAction` |
| `FinderServices.swift` | `FinderServices.backUp` |
| `Intents.swift` | `IntentTarget`, `JobEntity`, `JobEntityQuery`, `RunJobIntent`, `PauseAllJobsIntent`, `ResumeAllJobsIntent`, `CopiatorShortcuts`, `AppModel.runFromShortcut` |
| `StatusItems.swift` | `MenuBarContent`, `MenuBarLabel`, `DockProgress`, `VolumeWatcher` |
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
| New job status | `JobStatus` (+ `isActive`), `JobStatus.titleKey`, progress bar and badge switches in `JobListView`, `JobFilter` |
