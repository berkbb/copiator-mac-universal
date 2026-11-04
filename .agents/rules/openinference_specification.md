# OpenInference Specification Standard (`openinference_specification.md`)

> **Upstream Source:** <https://github.com/Arize-AI/openinference> (specification: <https://arize-ai.github.io/openinference/spec/>)
> **Version / Date:** The specification shows no version number; `openinference-semantic-conventions` 0.1.43 (PyPI, 2026-10-29) is the latest Python conventions package
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten for its per-job logs.

---

## Upstream Summary

- OpenInference is "a set of conventions and plugins that is complementary to OpenTelemetry to enable tracing of AI applications." The specification is transport- and file-format-agnostic and works with Arize Phoenix, Arize AX, or any OpenTelemetry-compatible collector.
- Each span carries `openinference.span.kind`, one of 11 kinds: LLM, AGENT, CHAIN, TOOL, RETRIEVER, RERANKER, EMBEDDING, GUARDRAIL, EVALUATOR, PROMPT, and DECISION. Attribute names use dot-separated namespaces such as `llm.input_messages`.
- Prompts and completions "must be maskable before export". `OPENINFERENCE_HIDE_*` environment variables (for example `OPENINFERENCE_HIDE_INPUTS`, `OPENINFERENCE_HIDE_OUTPUTS`, `OPENINFERENCE_HIDE_LLM_TOOLS`) default to `False`, and code-level `TraceConfig` overrides them.
- Semantic-convention packages exist for Python, JavaScript, Java, and Go.

## Core Requirements

1. **Report Every Span Kind Honestly:** Each TOOL step (a command run) is reported with its real outcome; a GUARDRAIL that blocked an action (a sandbox denial, a failed check, a denied permission, a hook) is reported as blocked, not left out; an EVALUATOR result (`swift test`) is quoted, not paraphrased into a pass.
2. **Never Quiet the Log:** Do not downgrade a job log's `.error` or `.warning` entries to `.info`, or drop them, to make a run look clean; the job inspector must show what happened, including verification differences and eject failures.
3. **Mask by Default:** A log line or notification an agent adds never contains passwords, tokens, file contents, or data from `~/.ssh`, `~/.gnupg`, `~/.aws`, or `~/Library/Keychains`. Paths shown to the user go through `OpenSafety.visibleName`, and test fixtures use dummy data.
4. **No Exporter in the App:** Copiator keeps its logs in `jobs.json` (`JobLogEntry`, `JobRun`) and shows them in the app. Adding OpenInference, OpenTelemetry, or any trace exporter breaks the on-device rule in `apple_app_intents_agent.md` and needs an explicit user decision.
5. **Agent-Side Tracing Stays Masked:** If the user approves tracing for agent tooling outside the app, it uses a local collector with `OPENINFERENCE_HIDE_INPUTS` and `OPENINFERENCE_HIDE_OUTPUTS` set to true.
