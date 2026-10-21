# Arize AI OpenInference Specification

- **Source:** Arize AI / OpenTelemetry (2024-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Defines observable state transitions and diagnostic error reporting.

## 2. Application in Copiator

- Summarize subprocess failures cleanly via `EngineError.diagnostic(from:)` and `RsyncOutcome.errorLines` (deceptive characters made visible) without leaking user data.
