# Uber Agentic AI Detection and Response Standard (`agentic_detection_response.md`)

> **Upstream Source:** <https://github.com/uber/ADR>
> **Version / Date:** Tag `sensor-v1.0.0` (2026-07-31); GitHub Releases lists no entries. License: Apache License 2.0 (vendored `Detection/benchmark/agentdojo/` is MIT).
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten (Copiator sends no telemetry).

---

## Upstream Summary

- ADR "secures enterprise AI agents through observability, security benchmarking, and threat detection". It is deployed at Uber.
- Discovery inventories the AI apps, CLI agents, IDE extensions, model runtimes and MCP servers on an endpoint. The Sensor collects and normalizes telemetry from Claude Code, Cursor, Codex, GitHub Copilot CLI and others.
- Detection has two tiers: high-recall triage, then deeper reasoning on suspicious sessions. ADR-Bench lists 300+ tasks, 134 MCP servers and all 17 agent attack techniques.
- The Explorer red-teaming engine "is not included here". Prevention "is not included in the current open-source release".

## Core Requirements

1. **Legible Sessions:** ADR detects threats from session telemetry, so agents keep their actions visible. That means no encoded or obfuscated commands, no disabling of hooks (including the Graphify `PreToolUse` reminder), shell history or logs, and no side effects hidden inside generated scripts.
2. **No Secrets in Sessions:** Agents never print, echo or paste tokens, SSH keys, API keys, passwords or the release signing key into commands, prompts, commits or logs. This complements the product-side credential protection in `meta_purple_llama_safety.md`.
3. **No Telemetry:** Copiator's network traffic is limited to the user-approved GitHub release check (`AppUpdateChecker`), an rsync update the user starts (`Scripts/update-rsync.sh`), and loopback requests to local model servers on 127.0.0.1 when AI suggestions are on; rsync itself runs with network denied. Adding a sensor, telemetry or upload path breaks the on-device rule in `apple_app_intents_agent.md` and needs an explicit user decision.
