# Anthropic Constitutional AI Alignment Standard

- **Source:** Anthropic (2024-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Applies explicit constitutional principles to guide safe, transparent, and aligned agent behavior.

## 2. Application in Copiator

- Never bypass security controls (`SandboxProfile`, `Quarantine`, `OpenSafety`, `StagedExtraction.secureSymlinks`).
- Never expose user passwords on command-line arguments; always use `stdin` pipes.
- Prioritize user data integrity by never modifying the source (no `--remove-source-files`, sources read-only in the sandbox) and by requiring explicit confirmation for `--delete`.
