# Apple App Intents & System Agent Protocol (AIAP) Standard

- **Source:** Apple Platform Architecture & Apple Intelligence System Standards
- **Version:** macOS 26 / iOS 26 Tahoe SOTA
- **Last Review Date:** 2026-10-21
- **Change Summary:** Codified native Apple platform App Intents tool calling, Private Cloud Compute (PCC) attestation, and local system agent boundaries.

---

## 1. Overview & Purpose

The **Apple App Intents & System Agent Protocol (AIAP)** defines how native macOS and iOS applications expose capabilities, data, and workflows to on-device Foundation Models and system-level autonomous agents (Siri, Spotlight, Finder Actions).

---

## 2. Architectural Invariants

### A. Declarative App Intents Schema
- Every system-accessible action must be modeled as a typed `AppIntent` conforming to Apple's Swift concurrency (`Sendable`, `MainActor` isolation where applicable).
- Intent parameters must declare semantic types (`@Parameter(title: ...)`), default values, and input validation bounds.

### B. On-Device Execution & Privacy Bounds
- All tool execution occurs within the client process or designated extension target (`.appex`) without sending user data to third-party endpoints.
- High-risk operations (deleting files at the destination with `--delete`, credential access) require explicit user consent prompts (`requestConfirmation`).

### C. Universal Finder & System Surface Integration
- Native tools must expose Quick Look previews (`QLPreviewingController`), Finder context services (`NSServices`), and Drag-and-Drop providers to integrate cleanly into the macOS system agent pipeline.
