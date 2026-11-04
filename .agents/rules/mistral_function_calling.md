# Mistral AI Function Calling & Agents API Standard (`mistral_function_calling.md`)

> **Upstream Source:** <https://docs.mistral.ai/capabilities/function_calling/> (Agents API: <https://docs.mistral.ai/agents/introduction>)
> **Version / Date:** Undated documentation pages (footer "Mistral AI © 2026"), content as read on 2026-11-03
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review (formerly `mistral_tool_binding.md`); upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- Function calling has five steps: the developer defines tools, the user asks, the model generates function arguments, the developer executes the function, and the model answers from the result. The model may chain another tool call before answering.
- Each tool is a JSON object with `"type": "function"` and a `function` block holding `name`, `description`, and a JSON Schema `parameters` object with `properties` and `required`.
- The docs say "the function execution lies on the user/developer side"; the model does not run the function itself.
- `tool_choice` is `auto` (default), `any` (forces tool use), or `none`. `parallel_tool_calls` defaults to `true`; `false` forces single calls. Results go back as a `role: "tool"` message with the function `name`, `content`, and a `tool_call_id` matching the call's `id`.
- The Agents API adds built-in connector tools (code execution, web search, image generation, document library), persistent conversations, and handoffs that let agents call other agents.

## Core Requirements

1. **Proposals Are Not Executions:** Copiator binds no tools to a model; its model answers are suggestions the user applies. For coding agents, a planned tool call is a proposal; deleting files, rewriting history, engine installs, and releases stay with the user.
2. **External Contracts Are Checked:** The rsync arguments built by `RsyncCommand` and the outputs Copiator decodes (`--info=progress2` in `RsyncProgressParser`, `-i` itemized changes in `ItemizeParser`, the `-ii` same-name dry run in `ConflictDetector`, exit codes and messages in `RsyncOutcome`, `rsync --version` in `EngineInfo.parse`), the `KEY=value` output of `update-rsync.sh` read by `EngineUpdateResult.parse`, and the Ollama and LM Studio JSON replies read by `LocalModelServer` are this repository's tool contracts. After a new rsync version, check them against `Vendor/rsync/NEWS.md`, a read-only run, and the real-engine suites (`EngineIntegrationTests`, `ChaosAndSecurityMatrixTests`), never from memory.
3. **Every Result Traces to Its Call:** Each reported outcome names the command or test that produced it, the way `tool_call_id` ties a result to its call.
4. **Parallel Calls Only for Independent Work:** Run tool calls in parallel only when they are independent reads; dependent edits and checks run in order.
