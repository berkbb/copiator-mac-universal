# IBM Granite Enterprise Agent Standard

- **Source:** IBM Research (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Applies enterprise-grade supply-chain verification, license compliance, and auditability.

## 2. Application in Copiator

- Verify downloaded rsync source releases via SHA-256 digest, then the built binary via Mach-O, `otool -L` (system libraries only) and version checks in `Scripts/update-rsync.sh` / `Scripts/build-rsync.sh`.
- Record engine provenance in `Vendor/rsync/SOURCE.txt` and preserve `THIRD_PARTY_NOTICES.md`.
