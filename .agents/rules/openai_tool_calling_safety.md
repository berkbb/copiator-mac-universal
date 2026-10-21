# OpenAI Swarm Tool Safety Protocol

- **Source:** OpenAI (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-21
- **Change Summary:** Adopted for `copiator-mac-universal` governance.

---

## 1. Overview

Sets strict safeguards for validating arguments, sandboxing subprocesses, and executing tool calls.

## 2. Application in Copiator

- All rsync arguments must place absolute file paths after `--` to prevent option injection and remote-host (`host:path`) misinterpretation.
- Never generate `--remove-source-files`; escape `*`, `?`, `[` and `\` in filter patterns (`RsyncCommand.escapePattern`).
- Execute external binaries inside `/usr/bin/sandbox-exec` with explicit `-D` parameter bindings.
