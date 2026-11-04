# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset
> **Single Canonical Roadmap:** the single source of truth for planned work. Shipped work goes to [`/CHANGELOG.md`](../../CHANGELOG.md) and is removed from this list.

**Status legend:** ⬜ Open · 🟡 Partially done.

---

## Open

### Features

6. ⬜ **[Medium] Multiple sources per job** (model already keeps sources as a single URL; needs a schema version bump with migration).

9c. ⬜ **[Low] `--read-batch` as its own job kind** (apply a batch file to a destination).
9e. ⬜ **[Medium] Apple Foundation Models adapter (real fine-tuning) — decision pending, raised on 2026-10-23.** A LoRA adapter for the on-device model needs Apple's Foundation Models adapter training toolkit (Apple Developer download, Python, a Mac with a lot of memory), a labelled dataset of folder and template choices in Turkish, English and Romanian, the Foundation Models adapter entitlement for the app, delivery through Background Assets, and retraining for every new system model version. Until then the app tunes Apple through guided generation, greedy sampling and order-reversal checks.
9f. ⬜ **[Low] Backup status widget — deferred on 2026-10-23.** Proposed together with the old backup reminder, snapshot restore, integrity check, duplicate finder and routine export/import (all shipped). A WidgetKit extension needs an app group shared with the app and a signed extension, so it stays blocked: the user chose ad-hoc signing (R4, 2026-11-04).

### Verification & Distribution

10. ⬜ **[High] Intel verification:** run the universal app and bundled rsync on an Intel Mac (the x86_64 slices are built and linked but untested).
13. 🟡 **[Medium] Hands-on check in the installed app — partly done on 2026-11-04.** Verified with an APFS disk image used as an external disk: start when the disk is connected, eject when done (the disk really ejected), the old backup reminder firing on mount (throttle recorded), integrity check on connect (now waits for the disk's jobs), the menu bar icon, and the stress round (core and app). The Dock progress was found not to show and was fixed the same day (a drawn green bar with the copy speed, verified during a real copy). Still open: Shortcuts and Siri actions (not driven, because the user was working on the Mac), a real external disk (the only one attached is the user's Time Machine disk, left alone), and the notification buttons (the user allowed notifications on 2026-11-04, so they can now be tried). Notifications themselves were found blocked by the app's location, not its signature (an app opened outside `/Applications` cannot ask); since then Copiator asks at launch and shows a banner that opens System Settings › Notifications › Copiator, both verified live on 2026-11-04. Second round on 2026-11-04 with 1.1.0 from `/Applications`, driven through the accessibility tree with a temporary test job: importing a setup file (job arrived paused), two snapshot runs, the fill forecast section, snapshot search (result opens the file in the newest snapshot) and compare (added, changed and removed files exactly right), the diagnostic report with a job (paths, user and folder names masked), the Settings permission rows and the low-priority switch all worked; the "open at login" row wrongly said the app was not in Applications (fixed: `.notFound` means never registered) and search results had no accessibility label (fixed). Not done: turning open at login on (adding a login item was refused by the auto-mode check; the user can try it), Quick Look, exporting a setup file, Shortcuts and Siri, and the notification buttons. Sheet buttons expose their names as `AXAttributedDescription` (System Events cannot print it); plain-style rows got explicit labels and `plainAndIconOnlyButtonsHaveLabels` guards them, but a full VoiceOver pass is still to be done by hand. The user tried the installed 1.1.0 by hand on 2026-11-04 and found it good; VoiceOver, Siri and Shortcuts and the notification buttons were not named and stay open.
