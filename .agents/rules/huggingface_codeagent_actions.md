# Hugging Face Actions-as-Code Standard (CodeAgent)

- **Source:** Hugging Face smolagents & CodeAgent Methodology
- **Version:** 2026.02
- **Last Review Date:** 2026-10-21
- **Change Summary:** Codified Actions-as-Code paradigm replacing verbose JSON schemas with deterministic executable scripts.

---

## 1. Overview & Purpose

The **Actions-as-Code (CodeAgent)** standard posits that autonomous agents are most reliable, flexible, and token-efficient when their reasoning outputs are expressed as **executable code blocks** rather than sprawling JSON tool-calling schemas.

---

## 2. Key Principles

### A. Code Over JSON Schemas
- Instead of multi-step JSON tool chains that require serialization round-trips for simple loops, agents generate concise, typed code snippets (Python, Swift, Bash) invoking pre-bound standard libraries.
- Reduces token footprint by up to $3\times$ while eliminating schema parsing ambiguities.

### B. Sandboxed Code Execution
- Executable code actions must run inside isolated subprocess environments (e.g., standard sandbox or containerized execution) with strict timeout boundaries.
- No direct dynamic `eval` in the main agent runtime.

### C. Immediate Error Feedback & Recovery
- Compiler errors, runtime exceptions, or syntax failures must feed directly into the agent's observation loop, enabling instant self-correction (ReAct loop).
