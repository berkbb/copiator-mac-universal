# Domain Wiki — Copiator Knowledge Asset

> **Memory Category:** TencentDB LLM-Wiki Knowledge Asset
> **Scope:** Domain workflows, the rsync CLI contract, security boundaries, job lifecycle and macOS integration.

---

## 1. System Overview

**Copiator** is a universal macOS backup and sync app (`arm64` + `x86_64`, macOS 26+) split into two SwiftPM targets:
- **`CopiatorCore`**: rsync argument generation, output parsers, outcome classification, sandbox profiles, disk-space guards, quarantine propagation, the engine-independent job model and queue rules, persistence, sleep assertions, engine discovery/updating, update signatures and localization tables.
- **`Copiator`**: `@MainActor` SwiftUI app (`AppModel`, `AppSettings`, Finder service, views).

Version 1.0 scope: local disk → local disk. Remote rsync over SSH and scheduled jobs were rejected by the user on 2026-10-21 (see `user_rejected_spec.md`).

## 2. rsync Command Contract (`RsyncCommand`)

| Operation | Arguments | Notes |
| :--- | :--- | :--- |
| **Transfer** | `-rltDhX --info=progress2 [-i] --partial [-pogA\|-pog] [--modify-window=1] [--delete] [--exclude=…] -- <source>[/] <destination>/` | `X` dropped when xattrs are off; `-pog*` never on exFAT/FAT/NTFS; `--modify-window=1` on FAT; trailing `/` on the source = "copy its contents". |
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

- Decided with the user on 2026-11-04 (roadmap 9l): the sandbox fails closed. When `/usr/bin/sandbox-exec` is missing, sandboxed jobs, previews and verifications are refused with a clear message; rsync runs without the sandbox only when the user turns the setting off.

1. **Kernel sandbox (`SandboxProfile.forTransfer`):** `(allow default)`, deny network, deny all writes, allow writes to `/dev` and the destination, then deny writes to the sources, deny reads of personal-data folders, then allow reads of explicitly chosen sources inside them, deny `mach-lookup`, deny `process-exec` except rsync's real path. Parameters are passed with `-D` (no quoting issues).
2. **Personal folders inside a source** (e.g. backing up `~`) are excluded with anchored patterns (`/Name/.ssh` in folder mode, `/.ssh` in contents mode) and logged (`logProtectedSkipped`).
3. **Overlap refusal (`JobValidation`):** the source's target (`destination/Name` or `destination`) must neither be inside the source nor contain it.
4. **Quarantine:** with xattrs off, `Quarantine.propagate` copies `com.apple.quarantine` from source items to fresh counterparts (owner write bit granted temporarily on read-only files).

## 4. Job Lifecycle

`waiting` → (`AppModel.start`) `scanning` (validation, size, free-space preflight) → `copying` (rsync running, progress events) → `finished` (success, notes, vanished) | `failed` (any other result) | `paused` (cancelled by the user or quit). `paused`/`failed` → resume → `waiting`; `finished` → run again → `waiting`. One job runs at a time; the queue can be held (`queueHeld`).

## 5. Release Packaging & Integrity

- `Scripts/package.sh`: tests → `build_app.sh` (universal app + bundled rsync, ad-hoc signed) → `verify_bundle.sh` → `.dmg` → Ed25519 `.dmg.sig` (keychain item `com.babadogantech.copiator.update-signing`, public key `CopiatorUpdatePublicEDKey`) → `SHA256SUMS.txt`.
- `Scripts/release.sh` tags `v<version>` and uploads with `gh release create`; no GitHub Actions.

## License

- Decided with the user on 2026-11-04: Copiator's own code is GPL-3.0-only (previously GPL-3.0-or-later). Every Swift source starts with `// SPDX-License-Identifier: GPL-3.0-only`; About, license viewer, `NSHumanReadableCopyright`, README and `THIRD_PARTY_NOTICES.md` say GPL-3.0-only. The `LICENSE` file is the unchanged GPLv3 text.
- The bundled rsync keeps its own GPL-3.0-or-later license (with its linking exception); lines that describe rsync (`Scripts/build-rsync.sh`, `Vendor/rsync/SOURCE.txt`, the engine entry of the license viewer) are not changed.
- The project the derived components come from is GPL-3.0-only with the same copyright holder (Babadogan Tech and Edu); the earlier MIT notice was outdated and was replaced. That project is named only in `THIRD_PARTY_NOTICES.md`.

## Agent Tooling

- Decided with the user on 2026-11-04 ("agents ler son sürüm yap. graphify yı ekle"): the `.agents/` rule files follow the current 42 Core Standards with their current names (nine files renamed, the invented reasoning-trace standard removed), and the documents link to each other and to Graphify.
- Graphify builds a local, code-only knowledge graph without an LLM (`.graphifyrc`, `.graphifyignore`, git-ignored `graphify-out/`). The project-scoped Claude Code skill and pre-search reminder (`CLAUDE.md`, `.claude/`) are versioned; git hooks and the merge driver are per clone. The skill files keep their Apache-2.0 license and are listed under "Repository-only files" in `THIRD_PARTY_NOTICES.md`; they are not part of the app.

## Dock Tile

- Decided with the user on 2026-11-04: the Dock tile looks like the sister download app's, a bright green progress bar drawn at the bottom of the icon with a pill showing the copy speed while a job runs, and no red number badge. The system progress control did not show in the Dock and is not used.

## Permissions (macOS privacy)

- Decided with the user on 2026-11-04: no waiting for a Developer ID. Notification permission is requested at launch (`AppModel.refreshPermissions(ask: true)`, options alert, sound and badge). The missing prompt was caused by the app's location, not its ad-hoc signature: the same ad-hoc build gets UNErrorDomain 1 "Notifications are not allowed for this application" when opened from `/tmp` or `build/`, and the system prompt when opened from `/Applications`.
- Curatare-style banners (`PermissionBanners`, top of the detail column, fixed height): notifications when the permission is denied or unavailable and a notifying setting is on (finish notifications, old backup reminder, integrity on connect); Full Disk Access when the probe says it is missing and a job or route path is inside or covers a protected location not skipped by the sandbox, or a job result has a sender-side "Operation not permitted (1)". "Later" hides a banner for the session; both are re-checked when the app becomes active. Decided with the user on 2026-11-04: whatever permission is needed is announced and asked for, so a Full Disk Access need that arises while the main window is hidden is also posted as one notification per launch, and Settings › General › Permissions shows both permissions with their System Settings buttons at any time.
- `FullDiskAccess.protectedLocations` lists home-relative folders that returned EPERM from a process without the permission on 2026-11-04 (Calendars, Reminders, Group Containers and iCloud Drive did not and are not listed). The probe opens TCC.db, Safari, Suggestions and CoreSpotlight; without the permission TCC.db reports ENOENT, the others EPERM.
- Ad-hoc signing ties TCC grants to the code hash, so Full Disk Access may stop working after an update while the switch still looks on; the banner and the README tell the user to toggle it. An Apple Development certificate would keep grants across builds but embeds the developer's e-mail in public binaries, so releases stay ad-hoc unless the user decides otherwise.
- `Info.plist` explains the on-demand prompts (Desktop, Documents, Downloads, removable and network volumes, file providers) in every language (`InfoPlist.strings`); `permissionPromptsAreExplainedInEveryLanguage` guards the key set.

## Log Window (Console)

- Added with the user on 2026-11-04 ("arhivar curatare gibi konsol"): the same three-way log as the sister archiver app (memory, private file under `~/Library/Logs/Copiator`, unified log with a public summary and private detail). Summaries never carry paths or file names; jobs appear as the first eight characters of their id. Tests keep the log in memory only.

## Undo Last Run

- Decided with the user on 2026-11-04 (roadmap 9d, "safe part"): snapshot jobs undo by moving the newest snapshot to the Trash; other jobs only move the items the last run created. Replaced or deleted files are never restored (no hidden backup folder), nothing is deleted permanently, and items that existed before the run or changed after it are never touched.

## Moving to Another Mac

- Decided with the user on 2026-11-04 (roadmap 9i): the setup file carries standalone jobs and portable settings only. Imported jobs always arrive paused. Security and consent choices (sandbox, update check, AI opt-in) and machine-specific paths are never exported or applied; routines keep their own export.

## Open at Login

- Decided with the user on 2026-11-04: Copiator can open at login (`SMAppService.mainApp`) so disk-triggered jobs, the old backup reminder and the integrity check on connect survive a restart. This is not scheduling (R1 stays rejected): the app only opens. The state belongs to macOS and is re-read, never stored; approval waits and "not found" are explained in Settings.

## App Icon

- Decided with the user on 2026-10-23: the icon drawn by `Scripts/make_icon.swift` is the final app icon (no longer temporary).

## Archive Health and Portability

- Decided with the user on 2026-10-23 ("Hepsi. Bildirim iyi fikir"): an old backup reminder, snapshot restore, an archive integrity check, a duplicate finder and routine export/import. A backup status widget was deferred until Developer ID signing (roadmap 9f).
- The reminder is a notification, not a schedule (time-based jobs stay rejected): it fires when a disk is connected and once at launch, only for jobs and routines that copy to that disk and have had no successful run for the chosen number of days (default 30), at most once a day per item. Jobs that start on their own when the disk is connected are left out.
- Restore never writes into a snapshot and never deletes: it queues an ordinary copy job to the original place or another folder, so same-name files are asked about.
- The integrity check distinguishes silent corruption (same size and date, different contents; reported until fixed) from legitimate changes (size or date changed; recorded). Its list is the only file Copiator writes at a destination by itself.
- Duplicates inside snapshot folders are intentional (hard links or kept history) and are not reported; extras go only to the Trash.
- Imported routines are always new routines; nothing is merged or replaced.
- Decided with the user on 2026-10-23 ("ilk üç yap diğerlerini roadmap a yaz"): repair damaged files from intact copies, eject the destination disk when done and buttons in notifications were built; snapshot search and compare, a fill forecast, low-priority I/O, moving jobs and settings, a diagnostic bundle and sleeping after the queue went to the roadmap (9g–9k, 7).
- Repair rewrites a damaged file only with a copy whose SHA-256 equals the digest recorded in the integrity list; any such copy is acceptable whatever its name, because the list, not the name, defines the correct contents.
- Eject is per job and routine and waits for everything that uses the disk (waiting, running or decision-waiting jobs, checks and repairs). A disk the user paused a job on can still be ejected.
- Clicking a notification only shows Copiator; work starts only from an explicit button ("Back Up Now").

## Copy Routines

- A routine is a named, reusable set of routes; each route is "files in this source folder that match these rules → this destination folder", keeping the folder structure. Several routes send different files to different places (decided with the user on 2026-10-22).
- Rules work like Finder smart folders: All / Any / None groups that can nest; conditions on name, extension, any folder name in the path, relative path (contains, is, begins with, ends with, regex) and file kind. Text matching ignores case (Turkish I/ı/İ/i alike); regexes are applied as written.
- Running a routine queues one job per route; the same jobs are requeued on later runs. Routines never delete at the destination and are not scheduled (time-based scheduling is rejected); they start manually, from the menu bar, from Shortcuts, or when the destination disk is connected.
- Advanced criteria (added on 2026-10-22 at the user's request, shown under "Advanced"): size, date modified/created/added, Finder tags, visibility, folder depth, extension lists, photo/video date taken, resolution, duration, camera model, and text inside files via Spotlight. Metadata is read only when a condition needs it; content search finds nothing on volumes without a Spotlight index. Spotlight folds case with the system locale (Turkish: "I" → "ı", "İ" → "i"), so the query searches every i-like letter as both "i" and "ı" to keep the rule's I/ı/İ/i-insensitive meaning.

## Same-Name Files at the Destination

- Decided with the user on 2026-10-22: every copy asks when a file with the same name already exists at the destination, even if the contents are identical. Choices: 1 · Replace, 2 · Keep Both (the incoming file gets a Finder-style number: "report 2.xlsx"), 3 · Skip; for all files or file by file; "remember for this job/routine" turns the choice into the job's or routine's policy.
- Unattended runs (e.g. a routine started by connecting a disk) pause as "Needs decision", notify and let the next jobs run.
- An item of another type under the same name is also asked about (rsync would delete it): a folder arriving where a file or link exists, a file arriving where an empty folder or a link exists. Keep Both for an incoming folder renames the existing item ("belgeler 2") instead of numbering the folder, so the folder's contents keep their place in the structure. A file arriving where a non-empty folder exists is refused by rsync (partial result, nothing lost).
- Only undecided files are listed in a sheet; decisions from earlier sheets are kept.
- Placement (added on 2026-10-22 at the user's request, from their `ev` archive scripts): routes may file documents into date folders and rename them from a template; dates come from the photo, the file name or the contents (Turkish, English and Romanian month names). Keep Both and same-name questions work on the new names.
- Requested together: a "copy with the same contents at the destination" criterion, sending Finder selections to a routine, a destination overview and folder suggestions in the routine editor. Moving or deleting the source, undo, cloud AI and two-way sync were left for a later decision.
- Decided with the user on 2026-10-22: move-to-Trash after a verified copy (opt-in, confirmed, never permanent deletion) plus a clean-up tool; two-way sync routines without deletions (ask, newer wins, A wins, B wins, skip); on-device AI suggestions only (Apple Intelligence, no cloud), always for approval. Undo was deferred.
- Naming modes and suggested placement (decided with the user on 2026-10-22, from the naming habits of their `ev` scripts, with no personal data in the app): text around `{name}` is not repeated, `{targetFolder}` and `{targetNumber}` (number in parentheses in the destination path, e.g. a subscriber folder) are tokens, name fixes are ordered regex replacements with upper/lower/title case. "Suggest a folder for each file and ask me" pauses the job before copying, preselects the best folder per file and copies only after Apply; "Remember" maps similar names (same words and extension apart from numbers and month names) to a folder for later runs. Works for external disks and folders on the Mac alike.
- The on-device model works best in English; the user asked for a visible warning that Turkish, Romanian and other names may get weaker suggestions.
- Decided with the user on 2026-10-22: Ollama and LM Studio (as in their Python scripts) can be chosen instead of Apple Intelligence, on 127.0.0.1 only and never with cloud models; Settings picks the provider and the local model. The AI may also suggest paths: a subfolder template from the destination's folders and, in the folder decision sheet, the folder for each file or a new folder when none fits. The language warning shows only while Apple Intelligence can answer. Then (same day) the user asked for an automatic mode: the three models answer in a chosen order with defaults and fallbacks, and an unreachable model must not cause an error; Automatic is the default model source. After the three-language evaluation (2026-10-23) the user kept Apple Intelligence first in the order and asked to tune Apple instead; a model error must never crash the app, the app must say the suggestion engine is unavailable, and all three models may be unavailable at once. The user then asked for rule-based templates, a fit check for new folders and a larger evaluation (81 questions in three languages plus a rules-only baseline). Next (same day): in Automatic mode, when Apple picks an existing folder the next ready model checks the fit and its decision wins on disagreement. Then (2026-10-23) the user made AI suggestions optional (off by default) with a prerequisite check when turning them on.
- "Replace" follows rsync's quick check: a same-name file with the same size and modification time counts as identical and is not rewritten.

## From the `ev` Scripts, Second Round (2026-11-07)

- Decided with the user on 2026-11-07 ("Şu 6 yı yapalım önce"), after comparing the `ev` archive scripts with Copiator: undo of a moving run, archive search, a name per file in the decision sheet, a run report, Windows and Office leftovers, and the small ones (photo location criterion, folder tree export, Dock drop).
- Undo of a moving run mirrors `ev`'s `perform_undo` (sources go back) but keeps Copiator's rules: the Trash is never emptied, nothing is restored over an existing file, and a copy whose source cannot come back stays.
- Archive search follows `ev`'s `--search` (name, PDF/text contents, photo data; open, extract a copy, delete) with "delete" replaced by "move to the Trash after confirmation" and "open" refusing kinds that can run code. EXIF GPS is only a yes/no criterion: turning coordinates into place names needs the network.
- The name per file follows `ev`'s `predict_standard_name` (imitate the names already in the chosen folder) through the existing rule-first template inference; the personal naming rules of the scripts (family names, plates, company prefixes) stay out of the app.
- Rejected for good by the existing rules, not proposed again: cloud models such as Gemini (on-device AI only), a batch mode where the AI places files without asking, permanent deletion, renaming the source in place.
- Decided with the user on 2026-11-07 ("Evet, ekle", after "OCR ı geç"): values from the contents go into names through route content fields (`{c:name}`, a regex with one capture group), not through AI and not through OCR. A missing value never yields a name with a gap: the file waits for a decision and only its name is asked. Content tokens are allowed in the name template only.
- Decided with the user on 2026-11-07 ("Evet, kapat. Tarih için de yap."), closing the last gaps to `ev`'s `auto_renamer`: the content criterion accepts regular expressions (for `\bASI\b`-style word matches), and an explicitly chosen date source that finds no date asks for the date in the decision sheet instead of using the date modified, the way `auto_renamer` skips a file without a date. "Automatic" keeps the date modified as its documented last step.

