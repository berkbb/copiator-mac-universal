# Apple App Intents & Native macOS Integration Standard (`apple_app_intents_agent.md`)

> **Upstream Source:** <https://developer.apple.com/documentation/appintents> & <https://security.apple.com/documentation/private-cloud-compute>
> **Version / Date:** macOS 26 (Tahoe) / 2026
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set, whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Copiator requirements rewritten for its App Intents, Finder services and on-device AI.

---

## Core Requirements

1. **Local On-Device Execution:** Copying, verifying, previews, snapshots, routines, sync, integrity checks, duplicates, and suggestions run on the Mac with no telemetry or uploads, and rsync runs with network denied in its `sandbox-exec` profile. The only connections are:
   - GitHub release checks: at launch only after the first-launch consent (`updateConsentAsked` and `checkUpdatesAtLaunch`), or when the user picks a "Check for … Updates" command. `AppUpdateChecker` reads the public release list and the Download button only opens the download link in the browser; `Scripts/update-rsync.sh` downloads and builds a new rsync only on the user's request.
   - Loopback requests to Ollama (127.0.0.1:11434) or LM Studio (127.0.0.1:1234) when the user turned AI suggestions on and chose them; no proxy, no redirects, cloud models excluded (`LocalModelServer`).
2. **On-Device Apple Intelligence Only:** AI suggestions are off by default (`AIPrerequisites` gate). Apple Intelligence is used through `SystemLanguageModel.default` on the Mac; Private Cloud Compute is never used, and answers are validated suggestions only (`AGENTS.md` invariant 22).
3. **App Intents Stay Thin:** `RunJobIntent`, `RunRoutineIntent`, `RunRoutineOnFilesIntent`, `PauseAllJobsIntent`, and `ResumeAllJobsIntent` (with `JobEntity`, `RoutineEntity`, and the Siri phrases in `CopiatorShortcuts`, localized in `AppShortcuts.strings`) only call the same `AppModel` functions as the menus. An intent never bypasses validation, the sandbox, the same-name decision, or the `--delete` confirmation, and every intent reaches the running app's model through `IntentTarget`.
4. **Safe Finder Services (`NSServices`):** "Back Up with Copiator" and "Send to a Copiator Routine" are declared under `NSServices` in `Support/Info.plist` (titles from `ServicesMenu.strings` in each `.lproj`) and handled by `FinderServices`. Incoming files go through the same validation and queue as in-app actions.
5. **New System Surfaces Need a Decision:** A widget (roadmap 9f), Control Center control, or any new system agent surface needs an explicit user decision and the signing it requires.
