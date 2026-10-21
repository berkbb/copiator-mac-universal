# OpenAI Model Spec

- **Source:** OpenAI (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Defines instruction authority hierarchy, safe autonomy, and untrusted data handling.

## 2. Application in Copiator

- Treat all source file names, symlinks, rsync output and downloaded engine releases as untrusted external data.
