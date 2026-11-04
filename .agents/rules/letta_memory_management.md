# Letta Memory Management Standard (`letta_memory_management.md`)

> **Upstream Source:** <https://github.com/letta-ai/letta-code> (Apache-2.0); Context Repositories announcement <https://www.letta.com/blog/context-repositories/>
> **Version / Date:** letta-code v0.34.39 (GitHub release, 2026-11-02); Context Repositories post dated 2026-02-12
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review (formerly `memgpt_os_memory.md`); upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- Letta Code is a stateful agent harness whose agents improve over time by rewriting their own memory, skills, and prompts. Its README credits the team behind Letta's original research project, and the `letta-ai/letta` README records Letta's former name (a retired name that this repository does not use).
- Memory blocks carry system prompt learning, and all context, memory blocks included, is tracked in git. Skills load at global, project, and agent scope.
- Context Repositories store memory as a local file tree that the agent reads and reorganizes with terminal tools, with every change committed to git. Each file has a frontmatter description; the folder layout and descriptions sit in the system prompt so details load only when needed, while files in a designated system folder stay pinned.
- Subagents write memory in their own git worktrees and merge back. Built-in skills cover memory initialization, background reflection, and defragmentation, which backs memory up and then reorganizes it into focused files.
- Not stated on the canonical page, so not adopted here: "tiered memory" as a named model (the README describes memory blocks and git-tracked context, not tiers). "Context Repositories" is named in the Letta blog post above, not in the README.

## Core Requirements

1. **Pinned vs. On-Demand:** Only the global `CLAUDE.md`, the repository's `CLAUDE.md` (Graphify rules), and `.agents/AGENTS.md` are read at the start of every task. Other `.agents/` files are opened when the task touches their topic, chosen through `about_rules.md` and each file's header; use the Graphify graph, `code_graph_wiki.md`, and `symbolic_memory_graph.md` for targeted symbol lookup instead of reading unrelated sources.
2. **Headers Describe the File:** Every `.agents/` file opens with a header block that says what it holds (as the rule files do), so an agent can pick files from the index without reading them in full.
3. **Memory Changes Are Git Diffs:** Edits to `.agents/` files are ordinary reviewed diffs, one memory change per commit in the global commit format. Agents commit only when the user asks and never rewrite published history.
4. **Back Up Before Defragmenting:** Splitting or merging memory files (for example the long `roadmap.md` or `reflexion_memory_log.md`) happens only at the user's request, starts from a clean git state so the old version stays recoverable, and updates every citation of a moved path in `AGENTS.md`, rule files, and skills in the same change.
5. **Parallel Writers Stay Apart:** Subagents that edit memory in parallel work in separate worktrees or on separate files; a conflict in the same file is merged by reading both versions, never by overwriting one.
