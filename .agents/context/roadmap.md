# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset
> **Single Canonical Roadmap:** the single source of truth for planned work. Shipped work goes to [`/CHANGELOG.md`](../../CHANGELOG.md) and is removed from this list.

**Status legend:** ⬜ Open · 🟡 Partially done.

---

## Open

### Features

6. ⬜ **[Medium] Multiple sources per job** (model already keeps sources as a single URL; needs a schema version bump with migration).
7. ⬜ **[Low] Low-priority I/O option** (e.g. `taskpolicy`-style background I/O for rsync); proposed again on 2026-10-23 and queued by the user.

9c. ⬜ **[Low] `--read-batch` as its own job kind** (apply a batch file to a destination).
9e. ⬜ **[Medium] Apple Foundation Models adapter (real fine-tuning) — decision pending, raised on 2026-10-23.** A LoRA adapter for the on-device model needs Apple's Foundation Models adapter training toolkit (Apple Developer download, Python, a Mac with a lot of memory), a labelled dataset of folder and template choices in Turkish, English and Romanian, the Foundation Models adapter entitlement for the app, delivery through Background Assets, and retraining for every new system model version. Until then the app tunes Apple through guided generation, greedy sampling and order-reversal checks.
9d. ⬜ **[Medium] Undo the last run — deferred by the user on 2026-10-22.** Only files a run created can be removed; replaced files would need a backup folder. Needs an explicit decision before any work.
9f. ⬜ **[Low] Backup status widget — deferred on 2026-10-23.** Proposed together with the old backup reminder, snapshot restore, integrity check, duplicate finder and routine export/import (all shipped). A WidgetKit extension needs an app group shared with the app and a signed extension, so it waits for item 11 (Developer ID signing).
9g. ⬜ **[Medium] Search and compare snapshots — proposed on 2026-10-23, queued by the user.** Find a file name across all snapshots of a job, show what was added, changed and removed between two snapshots (inode and size/date comparison, no rsync run needed) and preview files with Quick Look in the snapshot browser.
9h. ⬜ **[Low] Destination fill forecast — proposed on 2026-10-23, queued by the user.** Estimate from the run history (bytes per run, snapshot growth) and the volume's free space when the destination will be full ("about 5 months at this rate"), warn ahead of time and suggest a snapshot retention rule. Must be a range, never a single date.
9i. ⬜ **[Medium] Move jobs and settings to another Mac — proposed on 2026-10-23, queued by the user.** Like routine export/import: a versioned file with jobs (without history and logs) and settings, new identities on import, remapping of missing folders, no secrets and no personal paths outside the jobs themselves.
9j. ⬜ **[Low] Diagnostic bundle — proposed on 2026-10-23, queued by the user.** One file with the app and rsync versions, settings, job options and recent logs for bug reports; user names, home folder paths and file names masked, previewed before saving, never sent anywhere by the app.
9k. ⬜ **[Low] Sleep the Mac when the queue finishes — offered on 2026-10-23 together with "eject the destination disk when done", not requested yet.** An opt-in queue-level action that puts the Mac to sleep after the last job (never while a job waits for a decision or a disk), announced with a short countdown that can be cancelled.

### Verification & Distribution

10. ⬜ **[High] Intel verification:** run the universal app and bundled rsync on an Intel Mac (the x86_64 slices are built and linked but untested).
11. ⬜ **[Medium] Developer ID signing and notarization** (`SIGN_IDENTITY` is supported by `build_app.sh`). Distribution channel decided on 2026-10-21: **GitHub Releases** (`Scripts/release.sh` with `gh release create`); signing is still recommended so Gatekeeper does not block downloads.
13. ⬜ **[Medium] Hands-on check of the new automation in the installed app:** Shortcuts/Siri actions (after launching from `/Applications`), the menu bar window, the Dock progress and a real external disk mount/eject cycle, including the old backup reminder and the integrity check on connect (both covered only by tests and off-screen rendering so far).
