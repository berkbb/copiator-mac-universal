# OWASP Top 10 for Agentic Applications & LLMs (ASI) Standard

- **Source:** Open Web Application Security Project (OWASP) Agentic Security Initiative (ASI)
- **Version:** 2026.01
- **Last Review Date:** 2026-10-21
- **Change Summary:** Formulated top 10 vulnerabilities and defensive invariants for autonomous AI agents.

---

## 1. Top 10 Agentic Vulnerabilities & Defense Mandates

1. **ASI01: Agent Goal Hijacking & Runaway Loops**
   - *Threat:* Malicious inputs altering agent goals, causing infinite execution loops or resource exhaustion.
   - *Invariant:* All agent loops must enforce maximum iteration caps (`maxIterations`), timeout bounds, and human-in-the-loop interruption triggers.

2. **ASI02: Untrusted Inter-Agent Delegation (A2A Spoofing)**
   - *Threat:* Compromised subagents injecting hostile instructions or impersonating authority.
   - *Invariant:* Strict token validation, signature verification, and origin assertions on all delegated inter-agent messages.

3. **ASI03: Tool Poisoning & Shadow Tool Execution**
   - *Threat:* Manipulated tool descriptions or runtime schemas triggering unauthorized actions.
   - *Invariant:* Deterministic, compile-time tool schemas; schema integrity hashing; deny arbitrary eval.

4. **ASI04: Excessive Tool Permissions & Sandbox Escapes**
   - *Threat:* Agents executing shell commands or file operations outside constrained boundaries.
   - *Invariant:* Kernel-level isolation (`/usr/bin/sandbox-exec`, network deny, strict path allowlists).

5. **ASI05: Memory & RAG Ingestion Poisoning**
   - *Threat:* Corrupting persistent episodic memory (`reflexion_memory_log.md`) or vector stores to alter future behavior.
   - *Invariant:* Sanitized memory ingestion pipelines, immutable constitutional anchors, and provenance tracking.

6. **ASI06: Secret & Credential Exposure via Process Inspection**
   - *Threat:* Exposing passwords or API keys via command-line arguments visible in `ps` or `sysctl`.
   - *Invariant:* Zero CLI secret exposure; always pass sensitive parameters via closed `stdin` pipes.

7. **ASI07: Cascading Trust & Privilege Escalation**
   - *Threat:* Chaining low-privilege tools to achieve root/unauthorized filesystem or network modification.
   - *Invariant:* Least-privilege principle per tool execution; intermediate confirmation on destructive steps.

8. **ASI08: Deceptive File & Unicode Payload Injection**
   - *Threat:* Trojan Source characters (`U+202E`, bi-directional overrides) masking malicious file extensions.
   - *Invariant:* Sanitization and visible bracket escaping (`⟦U+XXXX⟧`) for all user-presented filenames.

9. **ASI09: Resource Exhaustion & Saturating Denial of Service**
   - *Threat:* Zip-bomb or multi-gigabyte payload decompression triggering memory exhaustion or integer overflow.
   - *Invariant:* Saturating arithmetic (`Int64.saturatingAdding`), maximum subprocess buffer limits, and disk space pre-flight checks.

10. **ASI10: Inadequate Audit Logging & Telemetry Loss**
    - *Threat:* Lack of forensic evidence following an agentic compromise or unexpected behavior.
    - *Invariant:* Comprehensive, non-truncating telemetry traces conforming to OpenInference / Uber ADR standards.
