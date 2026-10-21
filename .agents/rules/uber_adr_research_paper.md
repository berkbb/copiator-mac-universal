# Uber ADR Research Paper (arXiv:2605.17380, MLSys 2026 Industry Track)

- **Source:** Uber MLSys 2026 Industry Track (arXiv:2605.17380)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Documents the Sensor/Explorer/Detector architecture for securing tool-invoking systems against untrusted inputs.

## 2. Application in Copiator

- Maintain adversarial test coverage (`SandboxTests`, `FuzzTests`, `ParserTests`, `EngineIntegrationTests`) against hostile file names, crafted rsync output and sandbox escapes.
