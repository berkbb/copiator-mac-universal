# GitHub Spec Kit — Spec-Driven Development (SDD) Standard (`github_spec_kit.md`)

> **Memory Category:** Master Protocol Rule
> **Upstream Source:** <https://github.com/github/spec-kit> (README, `CHANGELOG.md`, and releases; CLI package `specify-cli`, installed with `uv tool install specify-cli`)
> **Version / Date:** Spec Kit 1.2.6 (2026-11-02)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; lifecycle protocol rewritten for Copiator modules and scripts.

---

## 1. Upstream Summary

- **Core SDD commands (README):** `/speckit-constitution`, `/speckit-specify`, `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`, `/speckit-converge`.
- **Supporting commands (CHANGELOG):** `clarify` refines the spec before planning, and the spec quality checklist is re-validated after it (0.8.16); `checklist` runs after `plan` (0.11.8); `analyze` checks consistency (0.11.3).
- **Bundled extensions:** `bug` (0.9.5; `specify extension add bug`; `/speckit-bug-assess`, `/speckit-bug-fix`, `/speckit-bug-test`), `assess` (0.13.0; `specify extension add assess`; `/speckit-assess-intake`, `-research`, `-define`, `-shape`, `-decide`), and `github` for turning tasks into issues (1.0.13). `/speckit.taskstoissues` is deprecated since Spec Kit v1.1.0 and must not be used.
- **Bundles, presets, workflows:** bundles package extensions, presets, and workflows for a role (first-party `bugfix` and `assess` bundles since 1.0.9). Workflows (`workflow.yml`) automate prompts, commands, gates, and shell tasks. A gate step rejects with `abort`, `skip`, or `retry` (0.15.2), and an interrupted gate prompt does not approve the gate (1.1.2).

## 2. Lifecycle Protocol for Copiator

1. **Constitution:** Enforce the `.agents/AGENTS.md` invariants: unmodified rsync as a separate process, the source never modified by rsync, `--delete` only when chosen and confirmed, the `sandbox-exec` profile, one argument source (`RsyncCommand`), same-name files asked about by default, routines and sync that never delete, placement that stays inside the destination, on-device and opt-in AI suggestions, archive health tools that only read, `tr`/`en`/`ro` parity, backward-compatible persistence, and Ed25519 release signing.
2. **Specify & Clarify:** Map user requirements to concrete `CopiatorCore` and `Copiator` modules, check `.agents/context/roadmap.md` and `.agents/context/user_rejected_spec.md`, and settle open questions with the user before planning.
3. **Checklist:** Before planning, confirm the spec covers `tr`/`en`/`ro` keys, the sandbox profile (network, writable and readable paths), what is written or removed at the destination and the source, the same-name decision, tolerant decoding of new persisted fields, and the rsync argument contract in `.agents/context/domain_wiki.md`.
4. **Plan, Tasks & Analyze:** Name real symbols from `.agents/context/code_graph_wiki.md` (or `graphify explain`), order tasks test-first, and check spec, plan, and code agree before implementing.
5. **Implement & Converge:** Verify with `swift test`, `./Scripts/build_app.sh`, and `./Scripts/verify_bundle.sh`, and keep `roadmap.md` and `CHANGELOG.md` in step with the change.
6. **Review Gates:** A gate between spec, plan, and implementation needs the user's explicit verdict; a skipped or interrupted gate counts as not approved.
7. **Issues:** Create GitHub issues from tasks only through the `github` extension, never the deprecated core `taskstoissues`, and only after the user approves (it publishes). Security findings never become public issues; they go to private GitHub Security Advisories.
8. **Tooling:** This repository has no `.specify/` directory; agents follow the lifecycle by hand. Installing `specify-cli` or running `specify init` needs the user's approval.
