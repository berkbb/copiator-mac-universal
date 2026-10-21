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
| `RsyncProgress.swift` | `TransferProgress`, `RsyncProgressParser` | `--info=progress2` parsing, units |
| `RsyncOutcome.swift` | `RsyncOutcome` (`classify`, `errorLines`, `messageBody`, `endsWithErrno`) | Exit code + stderr → `JobResult` |
| `ItemizeParser.swift` | `DiffEntry`, `ItemizeParser` | `-i` parsing, `\#ooo` unescaping |
| `Engine.swift` | `EngineInfo`, `EngineLocator`, `EngineUpdateResult`, `EngineUpdater` | Candidates, version/capability parsing, choice, updater wrapper |
| `TransferEngine.swift` | `TransferEngine`, `TransferEvent`, `EngineContext`, `VerifyReport`, `TransferEngines` | Engine-independent contract and registry |
| `RsyncEngine.swift` | `RsyncEngine`, `ProgressThrottle` | Preflight, sandbox, disk guard, run, classify, quarantine, verify |
| `Job.swift` | `JobKind`, `CopyMode`, `CopyOptions`, `JobStatus`, `JobResultKind`, `JobResult`, `JobLogEntry`, `TransferJob`, `JobValidation` | Codable job model with tolerant decoding |
| `JobStore.swift` | `JobStore`, `JobQueue` | Persistence and pure queue rules |
| `DiskSpace.swift` | `DiskSpace`, `InsufficientSpaceError`, `DiskSpaceGuard`, `FileSystemKind`, `OwnerAccess`, `Int64.saturatingAdding` | Space checks, file-system detection |
| `Quarantine.swift` | `Quarantine` | Quarantine propagation |
| `SleepAssertion.swift` | `SleepAssertion` | IOPMAssertion |
| `OpenSafety.swift` | `OpenSafety` | Deceptive character detection and visible names |
| `AppUpdate.swift` | `AppRelease`, `AppUpdateChecker`, `UpdateSignature`, `UpdateChecksums` | Release check and verification |
| `Localization.swift` | `AppLanguage`, `StringTable` (`resultMessage`, `logText`), `LKey` | Localization engine and keys |

### Target: `Copiator` (`Sources/Copiator/`)

| File | Primary Symbols |
| :--- | :--- |
| `CopiatorApp.swift` | `CopiatorApp`, `AppDelegate`, `AppCommands` |
| `AppModel.swift` | `AppModel`, `EngineStatus`, `UpdateState`, `AppUpdateState`, `OperationState`, `JobFilter`, `NewJobRequest`, `VerifyPresentation`, `AppLinks`, `AppInfo`, `WindowID` |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `KeyboardShortcutData`, `ShortcutAction` |
| `FinderServices.swift` | `FinderServices.backUp` |
| `Views/ContentView.swift` | `ContentView`, `OverlayTiming`, `ProgressOverlay`, `ToastView` |
| `Views/JobListView.swift` | `SidebarView`, `JobListView`, `JobRow`, `StatusBadge`, `JobDetailView` |
| `Views/NewJobSheet.swift` | `NewJobSheet`, `VerifyResultSheet`, `WelcomeView`, `EngineStatusView` |
| `Views/SettingsView.swift`, `AboutView.swift`, `LicenseViewerSheet.swift` | Settings tabs, About, `LicenseDocument` |

## 2. Impact Map

| Change | Also update |
| :--- | :--- |
| New rsync flag | `RsyncCommand`, `RsyncCommandTests`, `FuzzTests.commandBuilderInvariantsHoldForRandomPaths`, `domain_wiki.md` §2 |
| New result kind | `JobResultKind`, `RsyncOutcome`, `StringTable.resultMessage`, three `Localizable.strings`, `LocalizationTests` |
| New job field | `TransferJob` coding keys + tolerant decoding, `JobModelTests.decodesMinimalAndForwardJobs`, `snapshot_audit_skill.md` |
| New engine | `JobKind` case, `TransferEngine` implementation, `TransferEngines.engine(for:)`, integration tests |
| New UI string | `LKey` + three tables |
