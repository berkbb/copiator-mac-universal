# Symbolic Memory Graph — State Topology & Node Lookup

> **Memory Category:** TencentDB Symbolic Short-Term Memory Topo-Graph
> **Scope:** State machines, execution pipelines, and symbolic `node_id` lookup for `Copiator`.

---

## 1. Symbolic Node Lookup Table

| `node_id` | Symbol | File | Role |
| :--- | :--- | :--- | :--- |
| `N_APP_MODEL` | `AppModel` | `Sources/Copiator/AppModel.swift` | Queue owner, engine probe, updates, verify, persistence |
| `N_SETTINGS` | `AppSettings` | `Sources/Copiator/AppSettings.swift` | Preferences, shortcuts, localization |
| `N_QUEUE` | `JobQueue` | `Sources/CopiatorCore/JobStore.swift` | Pure transitions and ordering |
| `N_STORE` | `JobStore` | `Sources/CopiatorCore/JobStore.swift` | `jobs.json` |
| `N_ENGINE` | `RsyncEngine` | `Sources/CopiatorCore/RsyncEngine.swift` | Transfer and verify pipelines |
| `N_CMD` | `RsyncCommand` | `Sources/CopiatorCore/RsyncCommand.swift` | Arguments |
| `N_RUNNER` | `CommandRunner` | `Sources/CopiatorCore/CommandRunner.swift` | Process execution |
| `N_SANDBOX` | `SandboxProfile` | `Sources/CopiatorCore/Sandbox.swift` | SBPL |
| `N_PROGRESS` | `RsyncProgressParser` | `Sources/CopiatorCore/RsyncProgress.swift` | Progress |
| `N_OUTCOME` | `RsyncOutcome` | `Sources/CopiatorCore/RsyncOutcome.swift` | Result classes |
| `N_GUARD` | `DiskSpaceGuard` | `Sources/CopiatorCore/DiskSpace.swift` | In-copy floor |
| `N_SLEEP` | `SleepAssertion` | `Sources/CopiatorCore/SleepAssertion.swift` | Idle-sleep prevention |

## 2. Job State Machine

```mermaid
stateDiagram-v2
    [*] --> waiting: addJob (validated)
    waiting --> scanning: AppModel.start (first waiting, queue not held)
    scanning --> copying: phase(.copying) / first progress
    scanning --> failed: preflight problem (overlap, missing, no space)
    copying --> finished: succeeded / succeededWithNotes / sourceFilesVanished
    copying --> failed: partial / ioError / destinationFull / …
    copying --> paused: user pause (rsync 20) or quit (wasInterrupted)
    waiting --> paused: user pause
    paused --> waiting: resume
    failed --> waiting: resume
    finished --> waiting: run again
```

## 3. Transfer Pipeline (`N_ENGINE`)

```mermaid
flowchart TD
    A[JobValidation] --> B[DiskSpace preflight: source − existing ≤ free − reserve]
    B --> C[SandboxProfile.forTransfer + protectedPaths]
    C --> D[RsyncCommand.transfer]
    D --> E[DiskSpaceGuard.run → CommandRunner.run, records → RsyncProgressParser → ProgressThrottle]
    E --> F[RsyncOutcome.classify + errorLines]
    F --> G{xattrs copied?}
    G -- no --> H[Quarantine.propagate]
    G -- yes --> I[JobResult]
    H --> I
```
