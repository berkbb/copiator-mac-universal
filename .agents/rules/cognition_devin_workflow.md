# Cognition Devin Autonomous Software Engineering Standard (`cognition_devin_workflow.md`)

> **Upstream Source:** <https://docs.devin.ai> (pre-task checklist: `essential-guidelines/when-to-use-devin`, API overview, release notes); launch post <https://cognition.com/blog/introducing-devin-2-2>
> **Version / Date:** Devin 2.2 (Cognition launch post, 2026-02-24; the docs landing page names no product version); API v3 is current, v1 and v2 are legacy; release notes read up to the 2026-11-02 entry
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- Devin is presented as an autonomous AI software engineer that writes, runs, and tests code. The docs' rule of thumb: a task a person could finish in about three hours is a likely fit.
- Pre-task checklist: give explicit success criteria (passing tests, matching an existing pattern, CI green); plan complex work first with Ask Devin; supply context (examples, patterns, links, filenames); plan verification, because tasks with test suites, lint checks, or compilation steps do better; split large requests into smaller chunks.
- Devin 2.2 added a Linux desktop for computer-use testing of desktop apps, self-verification and auto-fix before a PR is opened, and one interface for planning, coding, and review.
- The API overview names v3 as current; v1 and v2 keep working during a deprecation period without new features. The 2026-10-23 release notes move Playbooks to Skills.
- Not stated on the canonical page, so not adopted here: a defined workflow "from investigation through validation". The docs give a checklist and best practices, not named phases.

## Core Requirements

1. **Success Criteria Before Edits:** Before editing, state the done condition in checkable terms: the `swift test` suites that must pass, the existing file whose pattern the change follows, and for user-facing text the `LKey` entries added to `tr`, `en`, and `ro`. A bug is first reproduced with a failing test in `Tests/`. This feeds the Specify and Checklist steps of `github_spec_kit.md`; it does not replace them.
2. **Size the Task:** A request that spans `RsyncCommand`, `CommandRunner` and `SandboxProfile`, `RsyncEngine`, `AppModel` flows, views, and localization is split into chunks that each build and pass `swift test` on their own. Independent chunks may go to parallel subagents, each with an explicit file scope.
3. **Self-Verify, Then Report What Ran:** Run `swift test` before declaring done; for bundle or engine changes also run `./Scripts/build_app.sh` and `./Scripts/verify_bundle.sh`. New guards are checked by removing them and seeing their test fail. The report lists each check and its result. A skipped or failing check, or a UI change nobody looked at in the running app, is reported as such, never as success.
4. **Auto-Fix Stops at Side Effects:** Fix loops (review comments, test failures) act only on the working tree. Commits, pushes, PRs, `Scripts/release.sh`, and an rsync engine install need the user's approval.
