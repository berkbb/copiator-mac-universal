# Sentinel Test Skill — Test Execution & Static Validation

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Before committing, packaging, or completing any code/resource change in `Copiator`.

---

## 1. Purpose

Validates `CopiatorCore` and `Copiator` across unit tests, live-rsync integration tests, sandbox denial tests, deterministic fuzz tests, off-screen SwiftUI rendering and trilingual (`tr`, `en`, `ro`) localization parity.

## 2. Standard Execution Procedure

### Step 1: Run the Full Swift Test Suite
```bash
swift test
```
- **Expected Result:** all suites pass (`RunnerTests`, `ParserTests`, `RsyncCommandTests`, `SandboxTests`/`LiveSandboxTests`, `EngineIntegrationTests`, `JobModelTests`, `LocalizationTests`, `HardcodedTextGuardTests`, `FuzzTests`, `ChaosAndSecurityMatrixTests` (11 disciplines), `PlacementTests`/`LivePlacementTests` (naming modes, name fixes), `PlacementDecisionTests`/`LivePlacementDecisionTests` (suggested placement), `ArchiveToolsTests`, `SourceTrashTests`, `SyncTests`, `SuggestionsTests` (live model case only when Apple Intelligence is available), `LocalModelsTests` (fake Ollama/LM Studio server on 127.0.0.1), `TemplateInferenceTests` (rule-based templates), `BackupFreshnessTests`, `SnapshotRestoreTests` (live rsync restore), `ArchiveIntegrityTests`/`LiveIntegrityTests` (corruption, the list survives `--delete`), `DuplicateFinderTests`, `RoutineTransferTests`, `ArchiveHealthAppTests`, `IntegrityRepairTests`, `DiskEjectTests`, `NoticeAndEjectAppTests`, `SyncAndAIAppTests`, `SpotlightContentTests` (when indexing is on), `AppUpdateTests`, `RunUndoTests` (moving runs put sources back), `RunReportTests`/`RunReportAppTests`, `ArchiveSearchTests`/`ArchiveSearchAppTests`, `PlacementNamingTests` (name per file), `WindowsLeftoverTests`/`LiveWindowsLeftoverTests`, `FolderTreeTests`, `AppModelTests`, `ChaosAndLoadAppTests`, `SettingsTests`, `OverlayTimingTests`, `LicenseViewerTests`, `ViewRenderTests`).
- **Real Engine Requirement:** integration suites use `Vendor/rsync/rsync` (or `$COPIATOR_RSYNC`). If it is missing, run `./Scripts/build-rsync.sh` so no suite is skipped.

- **Matrix Requirement:** the decoy-engine cases compile a small C program with `xcrun clang` (Xcode or the Command Line Tools). A new guarantee gets a matrix case that fails when the guarantee is removed; check it by temporarily removing the guarantee.

### Step 2: Opt-In Rounds (before a release, and after any change to the engine's run flow)
```bash
COPIATOR_VOLUME_TESTS=1 swift test --filter ForeignVolumeTests      # real FAT32 and exFAT disk images
COPIATOR_VOLUME_TESTS=1 swift test --filter LiveDiskEjectTests     # attaches an APFS disk image and ejects it
COPIATOR_OLLAMA_TESTS=1 swift test --filter liveOllama              # a real local Ollama model (no cloud models)
COPIATOR_LMSTUDIO_TESTS=1 swift test --filter liveLMStudio          # the real LM Studio (Bionic) server on 127.0.0.1:1234
COPIATOR_AI_EVAL=1 COPIATOR_AI_EVAL_REPORT=/path/report.md swift test --filter AIEvaluationTests  # tr/en/ro accuracy of every local model; fails if a provider has no local chat model
./Scripts/stress-test.sh                                            # large tree + real app round
```

### Step 3: Verify the Universal App Bundle (when packaging)
```bash
./Scripts/build_app.sh && ./Scripts/verify_bundle.sh
```
- Checks universal `Copiator` and `rsync`, rsync linked only to `/usr/lib`, updater scripts, license files, per-language strings and the code signature.

### Step 4: Provenance Audit
```bash
grep -rIli "arh[i]var" --exclude-dir=.build --exclude-dir=build --exclude-dir=dist --exclude-dir=graphify-out . | grep -v THIRD_PARTY_NOTICES.md
```
- **Expected Result:** no output (the derivation note in `THIRD_PARTY_NOTICES.md` is the only allowed mention).

### Step 5: Refresh the Code Graph (after code changes)
```bash
GRAPHIFY_NO_TIPS=1 GRAPHIFY_QUERY_LOG_DISABLE=1 GRAPHIFY_BACKEND=off graphify update .
GRAPHIFY_BACKEND=off graphify cluster-only . --no-label
```
- Local AST only, no LLM. Add `--force` to `update` when code was deleted. When types were added, moved or removed, update sections 1–2 of `.agents/context/code_graph_wiki.md` from `graphify-out/GRAPH_REPORT.md` (rules: `.agents/rules/graphify_knowledge_graph.md`). The installed git hooks run `update` after commits on their own.
