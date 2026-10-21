# Meta FAIR Agentic Safety Protocol

- **Source:** Meta FAIR (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Establishes safety boundaries against untrusted inputs, path traversal, and resource exhaustion.

## 2. Application in Copiator

- Defend against zip bombs using saturating `Int64` addition (`saturatingAdding`).
- Defend against symlink escapes using `StagedExtraction.secureSymlinks` and `ItemExtractor` prefix checks.
- Defend against extension spoofing using `OpenSafety.hasDeceptiveCharacters` and `visibleName`.
