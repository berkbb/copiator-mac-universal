# OpenAI Agents SDK Guardrails & Tool Safety Standard (`openai_agents_sdk_safety.md`)

> **Upstream Source:** <https://github.com/openai/openai-agents-python>
> **Version / Date:** 2026 Stable
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set (formerly `openai_tool_calling_safety.md`), whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Copiator requirements rewritten; the missing fail-closed check for `sandbox-exec` is recorded as a known gap.

---

## Core Requirements

1. **Pre-Execution Tripwires:** Every rsync invocation is built by `RsyncCommand` (absolute paths after `--`, filters escaped by `escapePattern`), and `RsyncCommand.assertSafe` rejects `--remove-source-files` and `--remove-sent-files`. `JobValidation.check` refuses jobs whose source and destination overlap, `--delete` appears only with the user's confirmed per-job choice, free space is checked before copying (`DiskSpace`), and a same-name dry run (`-n -ii`) runs before anything is written when the policy is Ask. While `sandboxEngine` is on (the default), `RsyncEngine` gives every run its `SandboxProfile`.
2. **Post-Execution Validation:** `RsyncOutcome` classifies the result (success, success with notes, source files vanished, stopped at limit, needs decision, failure classes) before anything else uses it. Verification after copy (`verifyAfterCopy`) lists remaining differences and fails the job as "not verified"; a snapshot is finalized and retention runs only after a fully successful run; sources go to the Trash only when their copies match by SHA-256.
3. **Known Gap — Sandbox Fallback:** `CommandRunner` runs the engine without `sandbox-exec` when `/usr/bin/sandbox-exec` is not executable (`SandboxProfile.isAvailable` is false); Settings disables the sandbox switch in that case but the run is not refused. Until the user decides to make it fail closed, agents must not widen this fallback or rely on the sandbox being present in tests that run without it.
