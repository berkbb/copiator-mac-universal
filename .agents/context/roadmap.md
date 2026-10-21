# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset
> **Single Canonical Roadmap:** the single source of truth for planned work. Shipped work goes to [`/CHANGELOG.md`](../../CHANGELOG.md) and is removed from this list.

**Status legend:** ⬜ Open · 🟡 Partially done.

---

## Open

### Engine & Job Kinds

1. ⬜ **[High] Remote rsync over SSH** as a new `JobKind` (`TransferEngine` implementation): host keys, `-e ssh` arguments built in `RsyncCommand`, a separate sandbox profile that allows only the SSH connection, credentials never on the command line.
2. ⬜ **[High] Scheduled jobs** (launchd agent or in-app scheduler) with missed-run handling and sleep/wake awareness.
3. ⬜ **[Medium] Additional engine** (e.g. aria2 for downloads) as another `JobKind`.
4. ⬜ **[Medium] Kill the whole rsync process tree on crash:** launch rsync in its own process group (posix_spawn `POSIX_SPAWN_SETPGROUP`) so an app crash cannot leave an orphaned rsync writing to the destination.

### Features

6. ⬜ **[Medium] Multiple sources per job** (model already keeps sources as a single URL; needs a schema version bump with migration).
7. ⬜ **[Low] Low-priority I/O option** (e.g. `taskpolicy`-style background I/O for rsync).
8. 🟡 **[Medium] Automatic snapshots:** `--link-dest` is available per job (the user picks the previous backup); still open: dated snapshot folders created automatically, "latest" tracking and retention rules.

9a. ⬜ **[Low] Edit options of an existing job** (today options are set when the job is added; a job can be removed and re-added).
9c. ⬜ **[Low] `--read-batch` as its own job kind** (apply a batch file to a destination).
9b. ⬜ **[Low] "Move" mode (`--remove-source-files`) — decision pending, deferred by the user on 2026-10-21.** It conflicts with the "source is never modified" invariant (`AGENTS.md` §1.1) and needs an explicit user decision before any work.

### Verification & Distribution

9. 🟡 **[High] Real-app stress round:** `Scripts/stress-test.sh` is written; its accessibility-driven app round has not run yet because the development session lacked the Accessibility permission. Run it from Terminal before 1.0 is published.
10. ⬜ **[High] Intel verification:** run the universal app and bundled rsync on an Intel Mac (the x86_64 slices are built and linked but untested).
11. ⬜ **[Medium] Developer ID signing and notarization** (`SIGN_IDENTITY` is supported by `build_app.sh`).
12. ⬜ **[Low] Final app icon** (current `make_icon.swift` design is temporary).
