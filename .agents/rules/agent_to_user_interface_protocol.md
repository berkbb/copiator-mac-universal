# Agent-to-User Interface Protocol Standard (`agent_to_user_interface_protocol.md`)

> **Upstream Source:** <https://a2ui.org> (repository: `a2ui-project/a2ui`)
> **Version / Date:** v0.9.1 current production release; v1.0 release candidate (previously designated v0.10 in draft); v0.9 previous stable; v0.8 legacy
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review (formerly `agent_to_ui_protocol.md`); upstream summary carried over without a new fetch; Copiator requirements rewritten for SwiftUI that coding agents write (Copiator has no A2UI renderer and shows no agent-generated UI at runtime).

---

## Upstream Summary

- A2UI ("Agent to User Interface") lets agents send declarative component descriptions, structure plus data, instead of "text-only responses or risky code execution"; clients render them with their own native widgets "across web, mobile, and desktop."
- Agents "can only use pre-approved components from your catalog", which the site presents as its "Secure by Design" defense against UI injection.
- Named renderers include Angular, Flutter, Lit, and Markdown; transports such as A2A carry A2UI messages. SwiftUI is not named.
- The site says A2UI is "Apache 2.0 licensed, created by Google" with contributions from CopilotKit and the open-source community; the repository lives under `a2ui-project`.

## Core Requirements

1. **Generated UI Is Reviewed Code:** SwiftUI an agent writes is executable code, not declarative data, so it gets the full review: build, `swift test` (including the off-screen view rendering in `CopiatorAppTests` and `HardcodedTextGuardTests`), and a check in the running app before it is reported as finished.
2. **Reuse the Catalog:** New views compose existing components and patterns from `Sources/Copiator/Views/` (`ProgressOverlay`, `ToastView`, `StatusBadge`, `ConflictSheet`, `PlacementDecisionView`, `FolderChooserRow`, `CommandPreview`, `AILanguageWarning`) and follow `ui_rules.md`. A new reusable component is a deliberate addition named in the report.
3. **Risky Controls Keep Their Guards:** A generated control that copies, deletes, moves to the Trash, repairs, ejects, or restores goes through the existing `AppModel` flows: the `--delete` confirmation, the same-name decision sheet (`ConflictPolicy.ask`), the move-to-Trash and duplicate confirmations, the integrity repair confirmation, and the sandboxed `RsyncEngine`. Generated UI never builds rsync arguments itself (`RsyncCommand` only) and never shows a raw file name without `OpenSafety.visibleName`.
4. **Every Label Is Localized:** Generated UI adds its strings as `LKey` entries with 1:1 parity in `tr`, `en`, and `ro`; no hardcoded text, and icon-only buttons carry accessibility labels (`HardcodedTextGuardTests`).
5. **No Runtime Agent UI:** Adding an A2UI renderer or any agent-driven interface to the app needs an explicit user decision first. AI suggestions stay suggestions inside existing native controls (`AGENTS.md` invariant 22).
