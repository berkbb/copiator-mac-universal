# UI Rules, Localization & SwiftUI Safety Standards

- **Source:** Project UI & Localization Governance (`Copiator`)
- **Version:** 1.0.0
- **Last Review Date:** 2026-10-21
- **Change Summary:** Initial Copiator UI rules: 1:1 trilingual localization, hardcoded string ban, list-row environment safety, accessibility identifiers, restart warning.

---

## 1. Strict Ban on Hardcoded UI Strings, Mandatory 1:1 Exact Translation & Dedicated File per Language

- Every user-visible string in `Sources/Copiator/` comes from `settings.t(.key)` with an `LKey` case (`Sources/CopiatorCore/Localization.swift`).
- Every `LKey` exists in `Resources/tr.lproj`, `Resources/en.lproj` and `Resources/ro.lproj` `Localizable.strings` (Turkish is the default language). `InfoPlist.strings` and `ServicesMenu.strings` exist per language with identical key sets.
- Format specifiers (`%@`, `%ld`, `%1$@`) and argument counts match 1:1. Only product names (`rsync`, `Copiator`) and genuinely identical words may stay the same across tables (`translationsAreNotEnglishFallbacks`).
- Engine output (rsync stderr lines) is shown raw in the job log but always through `OpenSafety.visibleName` so invisible or direction-changing characters are visible.

## 2. List Row Environment Safety

- Rows rendered inside `List`/`Table` (`JobRow`, `StatusBadge`) receive `model` and `settings` as explicit properties, never via `@Environment`: SwiftUI may re-insert rows without propagating environment objects.
- Every view change keeps `ViewRenderTests` green (off-screen rendering of all main screens; `COPIATOR_SNAPSHOT_DIR` writes PNGs for inspection).

## 3. Accessibility

- Icon-only buttons carry `.accessibilityLabel` (enforced by `iconOnlyButtonsHaveAccessibilityLabels`).
- Language-independent identifiers used by `Scripts/stress-test.sh`: `copiator.joblist`, `copiator.job`, `copiator.job.toggle`, `copiator.progress`, `copiator.progress.cancel`, `copiator.toolbar.newjob`, `copiator.newjob.add`, `copiator.newjob.delete`, `copiator.about.license.<document>`.
- Honor `accessibilityReduceMotion` in animated views (`ProgressOverlay`, transitions).

## 4. Progress Honesty

- While rsync reports `ir-chk`, the row shows `progressEstimating` and hides the time-left estimate.
- With an engine lacking `--info=progress2` (openrsync), progress is indeterminate and the row says `progressLimited`.
- The overlay (verify, engine update) shows "Cancelling…" immediately on cancel, closes immediately on cancel or failure, and shows a short 100 % beat on determinate success (`OverlayTiming`).

## 5. macOS MenuBar & In-App Language Switching Restart Warning Standard

- Changing the language shows the `restartWarningTitle` alert and the `restartMenuBarNotice` footer, and writes `AppleLanguages` so Cocoa menus and panels follow at the next launch.

## 6. Split-View Column Size Stability

- Content placed directly in a `NavigationSplitView` column or inspector (not inside a `ScrollView`, `List` or `Form`), and content in `.safeAreaInset` of such a column, must not have a minimum height that depends on its width. Do not use `.fixedSize(horizontal: false, vertical: true)` on wrapping text there; use `.lineLimit(1)` with truncation and put the full text in `.help`.
- Otherwise the column's minimum size changes on every layout pass, the split view recomputes constraints in a loop and AppKit terminates the app ("more Update Constraints in Window passes than there are views in the window").
- `PowerStatusBanner(wrapsText: false)` above the job list is the reference case; `WindowLayoutTests` runs the main window in an `NSHostingController` window with toolbar bridging and a running job, and crashes if the loop returns.
