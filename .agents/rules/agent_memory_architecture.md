# TencentDB Agent Memory Architecture Standard (`agent_memory_architecture.md`)

> **Memory Category:** Master Protocol Rule
> **Upstream Source:** <https://github.com/TencentCloud/TencentDB-Agent-Memory> (MIT)
> **Version / Date:** v2.0.0 (the README gives no release date)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; asset and tier mapping rewritten for Copiator files.
> **Scope:** Four Memory Assets (Chat Memory, Skill, LLM-Wiki, Code-Graph) and L0–L3 Memory Tiers.

---

## 1. Upstream Summary

- TencentDB Agent Memory is a team-level memory hub for AI agents that turns conversations, docs, and code into four reusable memory assets: **Chat Memory** (preferences, facts, decisions, interaction history), **Skill** (reusable expertise with versions, resource files, trigger boundaries, execution steps, and validation rules), **Wiki / LLM-Wiki** (docs, specs, and runbooks as structured, linked pages), and **CodeGraph / Code-Graph** (code symbols, files, call relationships, and impact paths).
- Chat Memory is layered: **L0 Conversation** (raw conversations with full context), **L1 Atom** (facts, preferences, constraints, and events extracted from them), **L2 Scenario** (knowledge blocks organized around projects or scenarios), **L3 Core / Persona** (long-term profiles, stable patterns, high-level cognition).
- Copiator uses the layout as a file convention only; it does not run the Memory Core, Proxy, Panel, or Hub services.

## 2. Four Memory Assets in Copiator

1. **Chat Memory:** Session context and user intent; the user's standing decisions live in `.agents/context/user_rejected_spec.md`, `.agents/context/roadmap.md`, and the dated decisions in `.agents/context/domain_wiki.md`.
2. **Skill (`skills/`):** Test and bundle validation (`sentinel_test_skill.md`), rsync engine build and update (`engine_maintenance_skill.md`), and settings, `jobs.json`, `routines.json`, and `Info.plist` compatibility audits (`snapshot_audit_skill.md`). Format for new skills: `agent_skills_specification.md`.
3. **LLM-Wiki (`context/domain_wiki.md`):** The rsync command contract (`RsyncCommand`) and the rsync facts verified on the bundled version, the sandbox and isolation architecture, the job lifecycle, routines, same-name decisions, archive health and portability, the license, and release signing.
4. **Code-Graph (`context/code_graph_wiki.md`):** Symbols, module dependencies, and impact paths, regenerated from Graphify (`graphify_knowledge_graph.md`).

## 3. Four-Tier Hierarchy (L0–L3) in Copiator

The global `CLAUDE.md` extends the upstream conversation tiers to project state; this repository follows that mapping (see also the table in `.agents/AGENTS.md`):

- **L0 Conversation / Execution Logs:** Session transcripts, `swift test` output, and command traces. Inside the app: each job's log (`JobLogEntry`, the last 500 per job) and run history (`JobRun`, the last 100 per job) saved in `jobs.json`; Copiator keeps no separate log file.
- **L1 Atom:** Constants and switches such as `DiskSpace.reserve` (1 GiB, at most 2 % of the volume), `DiskSpaceGuard.floor` (512 MiB), `CommandRunner.maxOutputBytes` (512 MiB), the 2-second `killGracePeriod`, `TransferJob.maxLogEntries` and `maxHistoryEntries`, `Suggestions.timeout` (90 s), `RoutineTransfer.maxSize` (10 MB), and the per-job options in `CopyOptions`.
- **L2 Scenario:** `AppModel` runtime state (`EngineStatus`, `JobStatus`, `runningJobID`, `OperationState`, `UpdateState`, pending decisions, integrity runs, pending ejects) and `AppSettings` preferences in `UserDefaults`, documented in `.agents/context/symbolic_memory_graph.md`.
- **L3 Core / Persona:** `.agents/AGENTS.md` constitutional invariants, the rules in `.agents/rules/`, and `user_rejected_spec.md`.
