# Domain Wiki — Copiator Knowledge Asset

> **Memory Category:** TencentDB LLM-Wiki Knowledge Asset
> **Scope:** Domain workflows, the rsync CLI contract, security boundaries, job lifecycle and macOS integration.

---

## 1. System Overview

**Copiator** is a universal macOS backup and sync app (`arm64` + `x86_64`, macOS 26+) split into two SwiftPM targets:
- **`CopiatorCore`**: rsync argument generation, output parsers, outcome classification, sandbox profiles, disk-space guards, quarantine propagation, the engine-independent job model and queue rules, persistence, sleep assertions, engine discovery/updating, update signatures and localization tables.
- **`Copiator`**: `@MainActor` SwiftUI app (`AppModel`, `AppSettings`, Finder service, views).

Version 1.0 scope: local disk → local disk. Planned job kinds: other engines (e.g. aria2). Remote rsync over SSH and scheduled jobs were rejected by the user on 2026-10-21 (see `user_rejected_spec.md`).

## 2. rsync Command Contract (`RsyncCommand`)

| Operation | Arguments | Notes |
| :--- | :--- | :--- |
| **Transfer** | `-rltDhX --info=progress2 --partial [-pogA\|-pog] [--modify-window=1] [--delete] [--exclude=…] -- <source>[/] <destination>/` | `X` dropped when xattrs are off; `-pog*` never on exFAT/FAT/NTFS; `--modify-window=1` on FAT; trailing `/` on the source = "copy its contents". |
| **Verify** | `-rltDhX -n -i [-c] [-pog…] --delete [--exclude=…] -- <source>[/] <destination>/` | Dry run; `--delete` lists extra items only; sandbox has no writable folder. |
| **openrsync (fallback)** | `-rltDh [--extended-attributes] --partial [-pog] …` | No `--info=progress2`, no `-X`, no ACLs; progress is indeterminate. Unsupported advanced options are dropped and logged. |
| **Advanced (per job)** | `--info=progress1\|2[,name1][,flist2][,stats2] [--no-inc-recursive] [-i]` + selection, attribute, link, write, comparison, reference, backup and output flags + `--filter/--include/--exclude/-F/--*-from` | All defaults add nothing. Verify keeps only comparison-affecting flags. Order of filters: protected, system, user. |

### rsync Facts Verified on 3.5.1

1. `--info=progress2` lines: `"   29.70K  81%    0.61kB/s    0:00:47 (xfr#4801, to-chk=1199/6041)"`; `ir-chk` while the incremental file list is still growing; some lines have no `(xfr#…)` group. At completion the time column is the elapsed time.
2. `-h` makes byte counts 1000-based with two decimals; rates are always 1024-based (`progress.c`).
3. Itemize (`-i`) codes are 11 characters (`YXcstpoguax`) then a space; deletions print `*deleting` padded to 11; non-printable bytes are escaped as `\#ooo`.
4. Exit codes: 0 ok, 1 syntax, 3 file selection, 4 unsupported, 11 file I/O, 12 stream, 20 SIGINT/SIGTERM (partial file kept with `--partial`), 23 partial transfer, 24 vanished source files, 30/35 timeouts.
5. Under `sandbox-exec` with `(deny network*)`, `(deny mach-lookup)` and `(deny process-exec)` except rsync itself, a local copy works (rsync forks and uses a socketpair, no exec); a blocked write reports `Operation not permitted (1)` and exit 23; a blocked connection reports `Operation not permitted` instead of `Connection refused`.
6. On macOS 27, exFAT and FAT32 destinations accept `-pogA` silently; FAT32 keeps times in 2-second steps, so re-runs recopy everything without `--modify-window=1`.
7. A shallow git checkout of the tag lacks `configure.sh`; rsync's `mkgitver` appends `-g<commit>` to the version when `.git` exists.
8. `--info=name1` prints names as `\n` lines between `\r` progress records; `--info=progress1` lines have the progress2 format but per-file values; `flist2` prints ` N files...` only with `--no-inc-recursive`; `stats2` prints a `Number of files:` block at the end.
9. `--stop-at`/`--stop-after` → `stopping at requested limit`, exit 30 (same code as a timeout).
10. Under the sandbox, `--link-dest` links only if the previous backup is writable (a hard link is a write on the existing file); `--files-from` inside a denied folder fails because rsync opens list files component by component; sources inside a denied folder with a file-level allow work.
11. This build reports `no prealloc`: `--preallocate` fails with "preallocation is not supported".

## 3. Security & Isolation Architecture

1. **Kernel sandbox (`SandboxProfile.forTransfer`):** `(allow default)`, deny network, deny all writes, allow writes to `/dev` and the destination, then deny writes to the sources, deny reads of personal-data folders, then allow reads of explicitly chosen sources inside them, deny `mach-lookup`, deny `process-exec` except rsync's real path. Parameters are passed with `-D` (no quoting issues).
2. **Personal folders inside a source** (e.g. backing up `~`) are excluded with anchored patterns (`/Name/.ssh` in folder mode, `/.ssh` in contents mode) and logged (`logProtectedSkipped`).
3. **Overlap refusal (`JobValidation`):** the source's target (`destination/Name` or `destination`) must neither be inside the source nor contain it.
4. **Quarantine:** with xattrs off, `Quarantine.propagate` copies `com.apple.quarantine` from source items to fresh counterparts (owner write bit granted temporarily on read-only files).

## 4. Job Lifecycle

`waiting` → (`AppModel.start`) `scanning` (validation, size, free-space preflight) → `copying` (rsync running, progress events) → `finished` (success, notes, vanished) | `failed` (any other result) | `paused` (cancelled by the user or quit). `paused`/`failed` → resume → `waiting`; `finished` → run again → `waiting`. One job runs at a time; the queue can be held (`queueHeld`).

## 5. Release Packaging & Integrity

- `Scripts/package.sh`: tests → `build_app.sh` (universal app + bundled rsync, ad-hoc signed) → `verify_bundle.sh` → `.dmg` → Ed25519 `.dmg.sig` (keychain item `com.babadogantech.copiator.update-signing`, public key `CopiatorUpdatePublicEDKey`) → `SHA256SUMS.txt`.
- `Scripts/release.sh` tags `v<version>` and uploads with `gh release create`; no GitHub Actions.

## Copy Routines

- A routine is a named, reusable set of routes; each route is "files in this source folder that match these rules → this destination folder", keeping the folder structure. Several routes send different files to different places (decided with the user on 2026-10-22).
- Rules work like Finder smart folders: All / Any / None groups that can nest; conditions on name, extension, any folder name in the path, relative path (contains, is, begins with, ends with, regex) and file kind. Text matching ignores case (Turkish I/ı/İ/i alike); regexes are applied as written.
- Running a routine queues one job per route; the same jobs are requeued on later runs. Routines never delete at the destination and are not scheduled (time-based scheduling is rejected); they start manually, from the menu bar, from Shortcuts, or when the destination disk is connected.
