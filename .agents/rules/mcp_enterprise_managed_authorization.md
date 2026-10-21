# MCP Enterprise-Managed Authorization Standard

- **Source:** Model Context Protocol Working Group (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Standardizes access control, permission boundaries, and auditability.

## 2. Application in Copiator

- Enforce `0o700` POSIX permissions on all temporary session and staging directories (`sessionDirectory`, `ItemExtractor`, `AddPlan`).
