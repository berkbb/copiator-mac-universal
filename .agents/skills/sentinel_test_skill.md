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
- **Expected Result:** all suites pass (`RunnerTests`, `ParserTests`, `RsyncCommandTests`, `SandboxTests`/`LiveSandboxTests`, `EngineIntegrationTests`, `JobModelTests`, `LocalizationTests`, `HardcodedTextGuardTests`, `FuzzTests`, `ChaosAndSecurityMatrixTests` (11 disciplines), `PlacementTests`/`LivePlacementTests`, `ArchiveToolsTests`, `SpotlightContentTests` (when indexing is on), `AppUpdateTests`, `AppModelTests`, `ChaosAndLoadAppTests`, `SettingsTests`, `OverlayTimingTests`, `LicenseViewerTests`, `ViewRenderTests`).
- **Real Engine Requirement:** integration suites use `Vendor/rsync/rsync` (or `$COPIATOR_RSYNC`). If it is missing, run `./Scripts/build-rsync.sh` so no suite is skipped.

- **Matrix Requirement:** the decoy-engine cases compile a small C program with `xcrun clang` (Xcode or the Command Line Tools). A new guarantee gets a matrix case that fails when the guarantee is removed; check it by temporarily removing the guarantee.

### Step 2: Opt-In Rounds (before a release, and after any change to the engine's run flow)
```bash
COPIATOR_VOLUME_TESTS=1 swift test --filter ForeignVolumeTests      # real FAT32 and exFAT disk images
./Scripts/stress-test.sh                                            # large tree + real app round
```

### Step 3: Verify the Universal App Bundle (when packaging)
```bash
./Scripts/build_app.sh && ./Scripts/verify_bundle.sh
```
- Checks universal `Copiator` and `rsync`, rsync linked only to `/usr/lib`, updater scripts, license files, per-language strings and the code signature.

### Step 4: Provenance Audit
```bash
grep -rIli "arh[i]var" --exclude-dir=.build --exclude-dir=build --exclude-dir=dist . | grep -v THIRD_PARTY_NOTICES.md
```
- **Expected Result:** no output (the derivation note in `THIRD_PARTY_NOTICES.md` is the only allowed mention).
