# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset
> **Single Canonical Roadmap:** the single source of truth for planned work. Shipped work goes to [`/CHANGELOG.md`](../../CHANGELOG.md) and is removed from this list.

**Status legend:** ⬜ Open · 🟡 Partially done.

---

## Open

### Engine & Job Kinds

3. ⬜ **[Medium] Additional engine** (e.g. aria2 for downloads) as another `JobKind`.

### Features

6. ⬜ **[Medium] Multiple sources per job** (model already keeps sources as a single URL; needs a schema version bump with migration).
7. ⬜ **[Low] Low-priority I/O option** (e.g. `taskpolicy`-style background I/O for rsync).

9c. ⬜ **[Low] `--read-batch` as its own job kind** (apply a batch file to a destination).
9e. ⬜ **[Medium] Apple Foundation Models adapter (real fine-tuning) — decision pending, raised on 2026-10-23.** A LoRA adapter for the on-device model needs Apple's Foundation Models adapter training toolkit (Apple Developer download, Python, a Mac with a lot of memory), a labelled dataset of folder and template choices in Turkish, English and Romanian, the Foundation Models adapter entitlement for the app, delivery through Background Assets, and retraining for every new system model version. Until then the app tunes Apple through guided generation, greedy sampling and order-reversal checks.
9d. ⬜ **[Medium] Undo the last run — deferred by the user on 2026-10-22.** Only files a run created can be removed; replaced files would need a backup folder. Needs an explicit decision before any work.

### Verification & Distribution

9. 🟡 **[High] Real-app stress round:** `Scripts/stress-test.sh` is written; its accessibility-driven app round has not run yet because the development session lacked the Accessibility permission. Run it from Terminal before 1.0 is published.
10. ⬜ **[High] Intel verification:** run the universal app and bundled rsync on an Intel Mac (the x86_64 slices are built and linked but untested).
11. ⬜ **[Medium] Developer ID signing and notarization** (`SIGN_IDENTITY` is supported by `build_app.sh`). Distribution channel decided on 2026-10-21: **GitHub Releases** (`Scripts/release.sh` with `gh release create`); signing is still recommended so Gatekeeper does not block downloads.
12. ⬜ **[Low] Final app icon** (current `make_icon.swift` design is temporary).
13. ⬜ **[Medium] Hands-on check of the new automation in the installed app:** Shortcuts/Siri actions (after launching from `/Applications`), the menu bar window, the Dock progress and a real external disk mount/eject cycle.
