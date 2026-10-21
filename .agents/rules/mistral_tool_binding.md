# Mistral AI Tool Binding Standard

- **Source:** Mistral AI (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Defines strongly typed schemas and contracts for binding external tools and CLI binaries.

## 2. Application in Copiator

- Encapsulate all rsync command-line switch generation in `RsyncCommand` (`Sources/CopiatorCore/`).
- Parse structured CLI outputs (`--info=progress2`, `-i` itemize output, `--version`, `update-rsync.sh` KEY=value output) through dedicated, unit-tested parsers.
