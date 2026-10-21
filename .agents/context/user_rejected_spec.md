# User-Rejected Specs & Anti-Feature Redlines

> **Memory Category:** TencentDB L3 Persona & Redline Constraints
> **Scope:** Architectural redlines, license boundaries, and UX anti-patterns that agents must never introduce.

---

## Redline Specifications (Strictly Forbidden)

1. **No Linking rsync:** rsync runs only as a separate process. Never embed or link rsync source into the Swift binary.
2. **No Source Modification:** never generate `--remove-source-files` / `--remove-sent-files`, never give the sandbox write access to a source, never "move" instead of copy.
3. **No Implicit Deletion:** `--delete` is never a default and never enabled without the per-job confirmation dialog.
4. **No Unsolicited Network Connections Before User Consent:** no request to `api.github.com` at launch unless `updateConsentAsked && checkUpdatesAtLaunch`.
5. **No Network for the Engine:** the rsync sandbox keeps `(deny network*)`. Remote (SSH) jobs were rejected by the user (see below), so there is no planned exception.
6. **No Unchecked `Int64` Addition on File Sizes.**
7. **No GitHub Actions Dependency for Releases:** packaging and publishing stay local (`Scripts/package.sh`, `Scripts/release.sh`).
8. **No Third-Party Runtime Libraries in the Bundled rsync:** no xxhash, zstd, lz4, OpenSSL or Homebrew libraries; `/usr/lib` only.

---

## User-Rejected Features (do not propose or implement)

| # | Feature | Rejected on | Notes |
|---|---------|-------------|-------|
| R1 | **Scheduled jobs** (launchd agent or in-app timer: hourly/daily/weekly runs, missed-run handling) | 2026-10-21 | Jobs start manually, from the Finder service, from Shortcuts, or when the destination disk is connected. Do not add a time-based scheduler. |
| R2 | **Remote rsync over SSH** (a remote `JobKind`, `-e ssh`, host keys, network access for the engine) | 2026-10-21 | Copiator stays a local copy and sync app; the engine sandbox keeps `(deny network*)`. |
