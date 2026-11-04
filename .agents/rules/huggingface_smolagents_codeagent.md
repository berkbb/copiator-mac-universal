# Hugging Face smolagents CodeAgent Standard (`huggingface_smolagents_codeagent.md`)

> **Upstream Source:** <https://github.com/huggingface/smolagents> (Apache-2.0); CodeAct paper "Executable Code Actions Elicit Better LLM Agents", Xingyao Wang, Yangyi Chen, Lifan Yuan, Yizhe Zhang, Yunzhu Li, Hao Peng, Heng Ji (<https://arxiv.org/abs/2402.01030>)
> **Version / Date:** smolagents v1.26.0 (GitHub release, 2026-05-29); CodeAct arXiv v4, 2024-06-07 (v1 2024-02-01; accepted by ICML 2024 per the arXiv comments field)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review (formerly `huggingface_codeagent_actions.md`); upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- smolagents is a minimal library for agents that think in code. `CodeAgent` writes its actions as Python snippets; `ToolCallingAgent` uses the model's built-in tool calling instead.
- The README says code actions work better than having the model output a dictionary of tool calls and use 30% fewer steps (and so 30% fewer LLM calls), linking the CodeAct paper for that figure.
- CodeAct has agents emit executable Python instead of fixed JSON or text actions, so they can combine tools and revise earlier actions from new observations over several turns. Across 17 LLMs it beat those alternatives by up to 20% in success rate.
- The README treats running agent code as arbitrary code execution: run it in a sandbox (E2B, Blaxel, Modal, or Docker). The built-in `LocalPythonExecutor` is not a security boundary.
- Not stated on the canonical page, so not adopted here: "deterministic execution" as a property of code actions. The CodeAct name appears in the paper, not in the README.

## Core Requirements

1. **One Script Over Many Calls:** When an answer needs many lookups (every `LKey` present in `tr`, `en`, and `ro`, every source file listed in `code_graph_wiki.md`, every mutation of a guard), prefer one read-only command or script whose output is the answer over dozens of single tool calls.
2. **Scripts Live Outside the Tree:** Such scripts go in the session scratchpad, never in the repository, and only read. A script that edits sources (a mutation run, a bulk header change) restores every file it touched and is shown to the user when it writes outside the repository or scratchpad.
3. **Agent Code Is Untrusted Code:** Code an agent writes runs as the normal user, never under `sudo`, and never reads `~/.ssh`, `~/.gnupg`, `~/.aws`, or `~/Library/Keychains`.
4. **Fix From the Error:** When a script fails, read the error and correct the script before trying again; the 3-Strike Rule in `react_agent_methodology.md` still applies.
5. **The App Keeps Its Own Boundary:** Inside Copiator, external programs run only through `CommandRunner` (`Foundation.Process`) with explicit argument arrays: rsync with `--` before paths and under `SandboxProfile`, and `update-rsync.sh` started by `EngineUpdater` as `/bin/bash` with the script path and fixed arguments (no `sh -c`, no user paths in a shell string). This standard does not justify an embedded interpreter or code-executing agent in the app.
