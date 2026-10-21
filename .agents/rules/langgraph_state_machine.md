# LangChain / LangGraph Cyclic State Machine Standard

- **Source:** LangChain / LangGraph (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Models stateful workflows as explicit, recoverable state transitions.

## 2. Application in Copiator

- Represent job states (`JobStatus`: waiting → scanning → copying → paused/finished/failed, applied through `JobQueue.apply`/`finish`) and one-off operations (`OperationState`) as explicit state machines.
- Ensure cancellation or error recovery leaves `AppModel` and disk destinations in a clean, consistent state.
