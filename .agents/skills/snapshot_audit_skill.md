# Snapshot & Compatibility Audit Skill

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Modifying `AppSettings` (`UserDefaults` keys), the job model (`TransferJob`, `CopyOptions`, `JobResult`), `jobs.json` handling or `Info.plist`.

---

## 1. Purpose

Audits backward compatibility of persisted preferences and jobs, and of Info.plist declarations.

## 2. Audit Checklist

1. **`UserDefaults`:** every persisted key is listed in `AppSettings.Key.all` and removed by `resetAll()`; `AppleLanguages` is removed last (`resetRemovesAllPreferences`).
2. **Job model evolution:** new fields are optional or decoded with `decodeIfPresent` defaults; unknown enum values fall back (`decodesMinimalAndForwardJobs`). Never rename or drop a stored key without a migration.
3. **`jobs.json`:** written atomically with `version`; unreadable files are moved to `jobs.corrupt-<time>.json` and reported (`corruptStoreIsSetAside`, `corruptStoreIsBackedUpAndReported`).
4. **`Support/Info.plist`:** version only via `./Scripts/set-version.sh`; `CFBundleLocalizations` lists `tr`, `en`, `ro`; every `NSServices` title has a `ServicesMenu.strings` entry in each language.
