# Engine Maintenance Skill — Bundled rsync

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Updating `Vendor/rsync`, changing `Scripts/build-rsync.sh` / `Scripts/update-rsync.sh`, or changing how rsync output is parsed.

---

## 1. Purpose

Keeps the bundled rsync reproducible, dependency-free and compatible with the parsers.

## 2. Standard Execution Procedure

### Step 1: Check or Update
```bash
./Scripts/update-rsync.sh check
./Scripts/update-rsync.sh install            # → Vendor/rsync (downloads tarball, SHA-256, builds, verifies)
./Scripts/build-rsync.sh --tag v3.5.1        # rebuild from the git tag (needs autoconf)
```
- `Vendor/rsync/SOURCE.txt` must record version, tag, commit (or tarball SHA-256), URL, binary SHA-256, archs, configure flags and dependencies.
- Dependencies must be `/usr/lib` only (`otool -L -arch all`). Capabilities must include `ACLs`, `xattrs` and `iconv`.

### Step 2: Re-validate Parsers Against the New Version
```bash
swift test --filter "ParserTests|EngineIntegrationTests|LiveSandboxTests"
```
- Re-capture real `--info=progress2`, `-i` and error lines if the NEWS mentions output changes, and update the fixtures in `ParserTests.swift`.

### Step 3: Licensing
- Keep `Vendor/rsync/COPYING` and `THIRD_PARTY_NOTICES.md` in sync with the new release; the About window shows the bundled `rsync-License.txt` (or the updated engine's `COPYING`).
