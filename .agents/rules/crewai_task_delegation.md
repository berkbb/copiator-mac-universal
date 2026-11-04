# CrewAI Multi-Agent Task Delegation Protocol (`crewai_task_delegation.md`)

> **Upstream Source:** <https://github.com/crewAIInc/crewAI> (official docs: <https://docs.crewai.com/en/concepts/agents>, <https://docs.crewai.com/en/concepts/tasks>)
> **Version / Date:** GitHub release `1.15.34` (2026-11-01)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- CrewAI is an MIT-licensed Python framework for multi-agent workflows. **Crews** are teams of agents; **Flows** are event-driven workflows with state management, branching, and routing.
- An agent has a `role`, `goal`, and `backstory`. `allow_delegation` lets it hand tasks to other agents and defaults to `False`; `max_iter` defaults to 20 and `max_retry_limit` to 2.
- A task has a `description`, an `expected_output`, an optional `agent`, and optional `context`: other tasks whose outputs feed this one, which it waits for.
- A task `guardrail` validates output before the next task starts; on failure the error goes back to the agent for another try, up to `guardrail_max_retries`. `human_input` asks a human to review the final answer (default `False`).
- Processes run tasks sequentially, or hierarchically with a manager that plans, delegates, and validates results.

## Core Requirements

1. **Scoped Tasks:** Every delegated task states its description, expected output, and the exact files it may change. A subagent does not re-delegate its whole task.
2. **Dependencies Are Explicit:** A task that builds on another receives that output in its brief and starts only after it arrives; parallel tasks never edit the same file.
3. **Guardrail Before Building On Output:** The delegating agent checks returned work (diff review, `swift test`, 1:1 key parity across `tr`, `en`, and `ro`) before using it. A failed check goes back with the error, within the 3-Strike limit.
4. **Human Review of the Final Answer:** Commits, pushes, and releases wait for the user, who reviews the combined result.
5. **No Crew in the App:** Copiator contains no multi-agent runtime; `FallbackSuggestionModel` asks local models one after another for a single suggestion, which is not delegation. This protocol governs only how coding agents divide work here.
