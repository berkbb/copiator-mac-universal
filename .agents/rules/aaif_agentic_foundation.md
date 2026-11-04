# Agentic AI Foundation Standard (`aaif_agentic_foundation.md`)

> **Upstream Source:** <https://aaif.io/> (pages reviewed: `/about`, `/projects`)
> **Version / Date:** No version; project list as published on 2026-11-03
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten (Copiator depends on none of the hosted projects).

---

## Upstream Summary

- AAIF is "a neutral, open foundation under the Linux Foundation" that "supports the people and projects building agents in the open."
- The `/projects` page lists ten hosted projects: Agent Router, Agent Skills, Agent2Agent (A2A), AGENTS.md, agentgateway, goose, Model Context Protocol (MCP), Open Responses, OpenEnv, and OpenSandbox.
- Governance: a Governing Board and a Technical Committee "Steering the technical direction of agentic AI"; working groups include Identity & Trust, Observability & Traceability, and Security & Privacy.
- The A2A project site dates A2A's acceptance as an AAIF Growth Stage project to 2026-08-27.
- Not stated on the canonical page, so not adopted here: the founding date 2025-12-09 and the claim that IBM ACP merged into A2A in 2025-08.

## Core Requirements

1. **Cite Current Names Only:** Name hosted projects as `/projects` lists them. Retired upstream names are never used as current names, and ACP is not cited as an AAIF project because the list does not include it.
2. **Check Membership Before Claiming It:** A rule file says a standard is AAIF-hosted only when `aaif.io/projects` or the project's own site says so on the review date, and it records that date.
3. **Hosting Is Not Trust:** A tool built on MCP, A2A, or goose is not trusted because the foundation hosts the protocol; `model_context_protocol.md` and `agent2agent_protocol.md` still apply.
4. **No Foundation Tooling in the App:** goose, agentgateway, Agent Router, and OpenSandbox are agent infrastructure, not Copiator dependencies. `Package.swift` declares no external package dependency (only the `Copiator` and `CopiatorCore` targets and their test targets). Adding one needs an explicit user decision first.
