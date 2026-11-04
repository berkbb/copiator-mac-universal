# Anthropic Claude Constitution Standard (`constitutional_principles.md`)

> **Upstream Source:** <https://www.anthropic.com/constitution>
> **Version / Date:** January 2026 Revision (supersedes the 2023 principle list)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set, whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Copiator requirements rewritten.

---

## Core Requirements

1. **Reasoning-Based Alignment:** Evaluate copy, delete, Trash, snapshot, engine, and release changes by their reversibility, blast radius, and respect for user autonomy rather than brittle keyword heuristics alone.
2. **User Data Integrity First:** Never let an operation lose or silently overwrite user files. rsync never modifies the source and resumes interrupted copies (`--partial`); deleting extra files at the destination needs the user's per-job choice and confirmation; same-name files are asked about by default (`ConflictPolicy.ask`); moving sources to the Trash happens only after their copies match by SHA-256 and never deletes permanently; snapshot pruning removes only folders whose names parse exactly as snapshots; integrity repair, duplicate clean-up, and disk eject wait for the user's confirmation or setting and re-check their preconditions just before acting.
3. **Never Bypass Security Controls:** Do not weaken or route around `SandboxProfile`, `RsyncCommand.assertSafe`, `Quarantine`, `OpenSafety`, `PlacementResolution.clean`, or the AI answer validation, and never let an AI answer act without the user.
