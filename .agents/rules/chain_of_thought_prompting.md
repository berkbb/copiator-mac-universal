# Google Research Chain-of-Thought Prompting

- **Source:** Google Research (Wei et al., 2022-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Decomposes complex multi-step problems into verifiable intermediate steps.

## 2. Application in Copiator

- Decompose multi-step operations (such as preflight → sandboxed rsync run → outcome classification → quarantine propagation) into independently testable functions.
