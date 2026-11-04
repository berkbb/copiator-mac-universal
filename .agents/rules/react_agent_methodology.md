# ReAct Agent Methodology Standard (`react_agent_methodology.md`)

> **Upstream Source:** <https://arxiv.org/abs/2210.03629> — "ReAct: Synergizing Reasoning and Acting in Language Models", Shunyu Yao, Jeffrey Zhao, Dian Yu, Nan Du, Izhak Shafran, Karthik Narasimhan, Yuan Cao
> **Version / Date:** arXiv v3, 2023-03-10 (ICLR camera-ready version per the arXiv comments field; v1 2022-10-06)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- ReAct has a language model produce reasoning traces and task actions in an interleaved way. Reasoning creates, tracks, and updates the action plan and handles exceptions; actions gather information from external sources such as knowledge bases or environments.
- On HotpotQA and FEVER, acting through a simple Wikipedia API reduced the hallucination and error propagation seen with chain-of-thought reasoning alone, and the trajectories were easier to interpret.
- On ALFWorld and WebShop, ReAct beat imitation and reinforcement learning baselines by 34% and 10% absolute success rate with one or two in-context examples.

## Core Requirements

1. **Observe Before Changing:** Before editing `RsyncCommand`, `CommandRunner`, `SandboxProfile`, `RsyncEngine`, `JobQueue`, or `AppModel` flows, gather observations first (the code graph through `graphify explain` or `graphify affected`, reading the source, running the relevant Swift Testing suite) and base the edit on them, not on memory.
2. **Check External Contracts by Acting:** rsync arguments, output formats, and exit codes are checked against `Vendor/rsync/NEWS.md`, the facts in `domain_wiki.md` ("rsync Facts Verified"), or a read-only run on a fixture, and `sandbox-exec` behavior against the live sandbox tests (`SandboxTests`), never assumed.
3. **Replan on Contradiction:** When an observation contradicts the plan (a failing test, unexpected command output), state the contradiction and change the plan before the next action. After three failures in a row on the same issue, stop, revert unstable edits, and ask the user (3-Strike Rule).
4. **Record Failed Trajectories:** Lessons from a failed or corrected trajectory go into `.agents/context/reflexion_memory_log.md`.
