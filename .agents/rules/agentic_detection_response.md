# Uber Agentic AI Detection and Response (ADR)

- **Source:** Uber Security & AI (2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Enterprise agentic security framework covering runtime containment, red-teaming, and two-tier detection.

## 2. Application in Copiator

- Enforce defense-in-depth: kernel sandboxing (`SandboxProfile`) + Swift-level symlink verification (`secureSymlinks`) + Gatekeeper quarantine propagation (`Quarantine.propagate`).
