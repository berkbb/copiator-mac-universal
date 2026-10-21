# Linux Foundation Agentic AI Foundation (AAIF) Architecture Standard

- **Source:** Linux Foundation (LF AI & Data / Agentic AI Foundation)
- **Version:** 2026.03
- **Last Review Date:** 2026-10-21
- **Change Summary:** Formulated open multi-agent protocol unification (MCP & A2A/ACP) and stateless Multi-Round-Trip Request (MRTR) standards.

---

## 1. Overview & Purpose

The **Agentic AI Foundation (AAIF)**, hosted by the Linux Foundation, defines the vendor-neutral governance and foundational protocol stack connecting Autonomous AI Agents to data, tools, humans, and other agents. It formally standardizes the unification of:
1. **MCP (Model Context Protocol):** Agent-to-data and agent-to-tool client-server interfaces.
2. **A2A / ACP (Agent2Agent Protocol & Agent Communication Protocol):** Agent-to-agent cross-framework task delegation.

---

## 2. Core Architectural Pillars

### A. Stateless Remote MCP & Multi-Round-Trip Requests (MRTR)
- **Stateless Scale:** Moves from connection-heavy persistent state to stateless HTTP/SSE transports suitable for cloud and local process execution.
- **MRTR:** Asynchronous, multi-turn request-response cycles enabling long-running tasks, tool approvals, and progress updates without timing out parent agent loops.

### B. Universal Agent Discovery & Manifests
- Agents publish structured capability manifests declaring:
  - Supported capabilities and domain roles.
  - Authentication and tokenization requirements.
  - Security boundary assertions (sandbox level, network deny, filesystem scope).

### C. Delegation & Contractual Handoffs
- Agent task handoffs must specify input contracts, output schemas, timeout boundaries, and fallback escalation channels.
