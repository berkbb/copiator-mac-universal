# Alibaba Qwen-Agent Code Interpreter Standard

- **Source:** Alibaba Qwen Team (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Governs isolated code execution, input handling, and deterministic result reporting.

## 2. Application in Copiator

- Run build and test commands inside the workspace sandbox first.
- Clean up temporary directories (`defer { try? fileManager.removeItem(at: ...) }`) in all tests and staging flows.
