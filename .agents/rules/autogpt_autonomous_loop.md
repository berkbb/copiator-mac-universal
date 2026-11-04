# AutoGPT Platform Continuous Autonomous Goal Loop Standard (`autogpt_autonomous_loop.md`)

> **Upstream Source:** <https://github.com/Significant-Gravitas/AutoGPT> (README and `classic/README.md`)
> **Version / Date:** GitHub release `autogpt-platform-beta-v0.10.0` (2026-10-27)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- The README presents AutoGPT as a team of AI "Experts" coordinated by an agent named Otto. Each Expert's role is shaped by instructions, context, skills, and connected apps; the Platform runs hosted (paid) or self-hosted with Docker.
- Users choose which accounts each Expert can access, set spending controls, and follow progress in each Expert's activity. The demo run prepares work "for review without sending or publishing it".
- The described cycle is choose an Expert, brief it, then review and refine; users can "Activate routines for jobs that keep coming back". A visual builder connects blocks and branch logic, and an API and MCP server run workflows from code.
- `autogpt_platform/` is under Polyform Shield; `classic/` and the rest are MIT. AutoGPT Classic is described as "an experimental project to demonstrate autonomous GPT-4 operation".
- Platform release tags carry the `beta` label (for example `autogpt-platform-beta-v0.10.0`).
- Not stated on the canonical page, so not adopted here: "continuous" operation or a plan, execute, evaluate, replan goal loop as a Platform feature.

## Core Requirements

1. **No Goal Loop in the App:** Copiator runs no agent loop. Every job starts from a user action (New Job, a routine, a Finder service, a Shortcuts action, a notification button) or from a rule the user set on the job (start when the destination disk is connected). Time-based scheduling is rejected (`user_rejected_spec.md`). At launch the app probes the engine, reaps orphaned rsync processes, and, with the user's consent, checks GitHub for updates; it never installs a Copiator update itself, and an rsync update installs only when the user starts it.
2. **Bounded Plan–Act–Check Cycle:** Coding agents plan, edit, run `swift test`, and replan on failure, stopping after three consecutive failures on the same issue (3-Strike Rule).
3. **Prepare for Review, Do Not Send:** Agents prepare commits, `CHANGELOG.md` release notes, and rsync engine updates for review; nothing is committed, pushed, tagged, released (`Scripts/release.sh`, `Yayimla.command`), or installed without the user's approval.
4. **Scoped Access and Spend:** Agents use only the access the task needs and add no paid cloud API, network service, or new account.
5. **Honest Completion:** A task is reported done only after its tests ran and passed; anything unverified is named as such.
