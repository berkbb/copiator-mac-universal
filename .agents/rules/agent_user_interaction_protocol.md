# Agent-User Interaction Protocol Standard (`agent_user_interaction_protocol.md`)

> **Upstream Source:** <https://docs.ag-ui.com> (repository: `ag-ui-protocol/ag-ui`)
> **Version / Date:** The docs show no protocol version; repository releases are date-tagged (latest `release/2026-11-03`), and `@ag-ui/core` 1.0.3 shipped in `release/2026-10-16`
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten for how coding agents report to the user (Copiator has no AG-UI client, server, or event stream).

---

## Upstream Summary

- AG-UI is "an open, lightweight, event-based protocol that standardizes how AI agents connect to user-facing applications"; the docs say it "was born from CopilotKit's initial partnership with LangChain and CrewAI." It builds on HTTP and WebSockets.
- Event categories: lifecycle (`RunStarted`, `RunFinished`, `RunError`, `StepStarted`, `StepFinished`), text message, tool call, state management (`StateSnapshot`, `StateDelta` as RFC 6902 JSON Patch, `MessagesSnapshot`), activity, subagent, reasoning, and `Raw`/`Custom`. The `THINKING_*` events are deprecated for removal in 1.0.0.
- Building blocks include shared state, frontend tool calls as typed handoffs, and Interrupts that let a user pause, approve, edit, retry, or escalate mid-flow.
- The docs place AG-UI at agent-to-user, MCP at agent-to-tools and data, and A2A at agent-to-agent; A2UI is a separate generative UI specification that works with AG-UI. The docs name no foundation or governance body.

## Core Requirements

1. **Every Run Ends Honestly:** Like `RunFinished` versus `RunError`, a turn ends by saying what finished and what failed. A failed or skipped step is never summarized as done.
2. **State Matches Reality:** Task lists and progress updates are snapshots of what actually happened; a step is marked complete only after its check ran.
3. **One Decision per Interrupt:** When work needs the user, pause at that point with one clear question (approve, edit, retry, or stop) instead of continuing and asking afterward or bundling several approvals. The app follows the same idea: a job with same-name files or folder questions pauses as "Needs decision" before anything is copied.
4. **Reasoning Is Not Evidence:** Results cite command output, diffs, and file paths, not the agent's own reasoning text.
5. **No Agent Runtime in the App:** The Copiator UI talks only to its own engine (`AppModel` driving rsync through `RsyncEngine` and `CommandRunner`). Adding an AG-UI client or event stream needs an explicit user decision first.
