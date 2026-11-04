# Uber ADR Research Paper Standard (`uber_adr_research_paper.md`)

> **Upstream Source:** <https://arxiv.org/abs/2605.17380> ("ADR: An Agentic Detection System for Enterprise Agentic AI Security", Li et al.)
> **Version / Date:** arXiv v1, submitted 2026-05-17; Comments: "Accepted at MLSys 2026 (Industry Track)"
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- The paper names three challenges in securing MCP-based agents: limited observability, weak robustness against varied attacks, and the high cost of LLM-based detection at scale.
- ADR has three parts. The Sensor collects agentic telemetry. The Explorer runs pre-deployment red teaming and generates hard examples. The Detector runs two-tier online detection: fast triage, then context-aware reasoning.
- ADR has been deployed at Uber for over ten months, covering more than 7,200 unique hosts and more than 10,000 agent sessions a day. It found hundreds of credential exposures across 26 categories. A shift-left prevention layer detected 206 credentials at 97.2% precision.
- On ADR-Bench (302 tasks, 17 techniques, 133 MCP servers), ADR has zero false positives and detects 67% of attacks. Its F1 score is 2–4x that of ALRPHFS, GuardAgent and LlamaFirewall. On AgentDojo it detects all attacks, with three false alarms across 93 tasks.
- The repository README gives slightly different ADR-Bench counts (300+ tasks, 134 MCP servers). The figures above are the abstract's.
- Not stated on the canonical page, so not adopted here: AgentDojo as a baseline (the abstract calls AgentDojo a public prompt injection benchmark; the baselines are ALRPHFS, GuardAgent and LlamaFirewall).

## Core Requirements

1. **Evidence, Not Claims:** Cite the paper's figures only as Uber's results, with the arXiv version. Never present them as properties of Copiator.
2. **Credentials First:** Credential exposure was the main finding in production, so agents check every diff for secrets and personal data before proposing a commit (a working-tree `grep -rI` scan, which also sees untracked files); `.secrets/` stays git-ignored. Tests and fixtures use dummy values only (dummy account numbers such as 123456789, temporary folders), never real tokens, user names or home paths.
3. **Benchmark Results Are Not Production Data:** Keep ADR-Bench and AgentDojo results separate from deployment telemetry when summarizing or comparing detectors.
