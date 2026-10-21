# TencentDB Agent Memory Architecture Standard

- **Source:** TencentDB Agent Memory Team (2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Defines the Four-Tier Memory Pyramid (L0 Execution Logs, L1 Atomic Parameters, L2 Scenario Engine States, L3 Persona & Governance) and four durable memory assets (LLM-Wiki, Code-Graph, Reflexion Episodic Log, and Procedural Skills).

## 2. Application in Copiator

- Store raw execution traces in L0 logs without polluting L2/L3 context.
- Keep atomic constants (reserves, timeouts, cache limits) in L1 parameter definitions.
- Synchronize runtime state transitions in L2 (`symbolic_memory_graph.md` and `domain_wiki.md`).
- Enforce constitutional invariants and user preferences in L3 (`AGENTS.md` and `user_rejected_spec.md`).
