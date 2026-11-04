# Graphify Labs Codebase Knowledge Graph Standard (`graphify_knowledge_graph.md`)

> **Upstream Source:** <https://github.com/Graphify-Labs/graphify> (PyPI: `graphifyy`; Apache-2.0, see `.claude/skills/graphify/LICENSE` and `NOTICE`)
> **Version / Date:** graphifyy 0.9.101 (installed with `uv tool install graphifyy`)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: initial adoption in Copiator. `.graphifyrc` (`key=value` format) and `.graphifyignore` added, `graphify-out/` git-ignored, first code-only offline build regenerated `.agents/context/code_graph_wiki.md`, the project-scoped Claude Code skill and `PreToolUse` hook installed (`graphify install --project --platform claude`), git hooks and the `graph.json` merge driver installed (`graphify hook install`), and the skill's Apache-2.0 license recorded in `THIRD_PARTY_NOTICES.md`.

---

## 1. Core Principles

1. **Graph-First Code Navigation:** The repository's code (Swift and shell via local tree-sitter AST) is turned into a queryable knowledge graph with `EXTRACTED` and `INFERRED` edge provenance and Leiden community detection.
2. **Query Before Grep:** When `graphify-out/graph.json` exists, query it (`graphify query`, `graphify path`, `graphify explain`, `graphify affected`) before broad search-style tool calls, and read raw files only for the lines the graph located. Put this rule in every subagent prompt that explores code.
3. **Artifact Sync:** Outputs live in `graphify-out/` (`graph.json`, `graph.html`, `GRAPH_REPORT.md`) and feed the Code-Graph Memory Asset (`.agents/context/code_graph_wiki.md`). `graphify-out/` is git-ignored and regenerable; never commit it.
4. **Privacy Boundary:** Only code parsing is local (tree-sitter, no LLM). A full build (`/graphify .` in an agent, or `graphify extract` without `--code-only`) sends docs and images to the host assistant's model or to the backend set by `GRAPHIFY_BACKEND`; use `GRAPHIFY_BACKEND=ollama` when that pass must stay local. This repository builds code-only and offline. Privacy is set through the environment, not `.graphifyrc`, which only accepts `viz_node_limit` and `language.<ext>=<language>`:
   ```bash
   GRAPHIFY_NO_TIPS=1 GRAPHIFY_QUERY_LOG_DISABLE=1 GRAPHIFY_BACKEND=off graphify extract . --code-only
   GRAPHIFY_BACKEND=off graphify cluster-only . --no-label
   ```
   `GRAPHIFY_BACKEND=off` stops graphify from picking an LLM backend from ambient API keys; `--no-label` keeps community naming local. Never enable the hosted Graphify platform unless the user asks for it.
5. **Ignore List Before the First Build:** `.graphifyignore` excludes build outputs, `graphify-out/`, `.claude/`, all of `Vendor/` (the bundled rsync), and credential or private-data patterns (`.secrets/`, `.env*`, keys, certificates, `*.csv`, `*.sql` dumps, `*.xlsx`).
6. **Refresh After Structural Changes:** After a change that adds, moves or deletes types, run `graphify update .` (code only, no LLM; add `--force` when code was deleted), then `cluster-only` as above, and update sections 1–2 of `code_graph_wiki.md`. The installed git hooks run the update after commits, checkouts, merges and rewrites.

## 2. Agent Integration (installed in this repository)

| Piece | Installed by | Files |
| :--- | :--- | :--- |
| Project-scoped skill (`/graphify`) | `graphify install --project --platform claude` | `.claude/skills/graphify/` (with `LICENSE`, `LICENSE-MIT`, `NOTICE` copied from the package), `.claude/CLAUDE.md` |
| Claude Code rules and `PreToolUse` hook (`Bash|Grep` search, `Read|Glob` read; reminder only, not `--strict`) | same command | `CLAUDE.md`, `.claude/settings.json` |
| Git hooks (post-commit, post-checkout, post-merge, post-rewrite) and `graph.json` merge driver | `graphify hook install` | `.git/hooks/*` and local `git config merge.graphify.*` (not versioned), `.gitattributes` line `graphify-out/graph.json merge=graphify` |

- A global `graphify install`, other platforms (`gemini`, `codex`, `cursor`) or `--strict` only when the user asks for them.
- The skill files are third-party content: keep the license copies next to them when the skill is updated, and keep the Graphify section of `THIRD_PARTY_NOTICES.md` in step with `.claude/skills/graphify/.graphify_version`.
- A fresh clone gets the skill and hook from git but not the git hooks or merge driver; run `graphify hook install` once per clone.

## 3. Application in Copiator

- Build: 130 code files (122 Swift, 8 shell) → 4,092 nodes, 10,456 edges, 130 communities at commit `4dc138c` (2026-11-04); see `code_graph_wiki.md` for hubs and known gaps (a test-only `enum Task` in `AIEvaluationTests` collides with Swift concurrency `Task`, and `LKey` cases look isolated because `.strings` tables are not indexed).
- Graph answers do not replace the constitutional checks in `.agents/AGENTS.md`: a change to `RsyncCommand`, `SandboxProfile`, `CommandRunner`, `RsyncEngine`, or `JobQueue` still needs its tests, and `graphify affected "<type>"` is the starting point for finding them.
