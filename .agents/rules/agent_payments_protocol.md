# Agent Payments Protocol Standard (`agent_payments_protocol.md`)

> **Upstream Source:** <https://ap2-protocol.org> (specification: <https://ap2-protocol.org/ap2/specification/>)
> **Version / Date:** Specification v0.2 (released 2026-04-28 per the Google announcement the canonical page links to)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; recorded as a boundary rule only (Copiator has no commerce and no payments).

---

## Upstream Summary

- AP2 is an open protocol for agent commerce. It extends A2A and integrates with UCP. On 2026-04-28 Google announced v0.2 and the donation of AP2 to the FIDO Alliance. Work continues in FIDO's Agentic Authentication Technical and Payments Technical Working Groups.
- v0.2 defines two mandate types. The Checkout Mandate goes to the merchant. The Payment Mandate goes to the credential provider, the network and the merchant payment processor. Each mandate has an open stage (constraints) and a closed stage (a specific checkout or amount).
- Mandates are SD-JWT verifiable digital credentials, chained into an audit trail. In human-present flows, the user approves the closed checkout on a Trusted Surface. In human-not-present flows, the user approves constraints in advance and an agent key signs the closed mandates.
- Not stated on the canonical page, so not adopted here: Intent and Cart Mandates (v0.2 defines only the Checkout and Payment Mandates).

## Core Requirements

1. **No Payments in Copiator:** Copiator is a free GPL-3.0-only backup and sync app with no purchase, subscription, or payment code. Adding AP2 or any other payment flow needs an explicit user decision first.
2. **No Mandates Without the User:** Agents never create, sign or approve a mandate, never enter payment details, make purchases or accept terms, and never set up a human-not-present flow. Any purchase needs the user's explicit confirmation of the item and the total.
3. **Keys Stay Out of the Repository:** User credentials, agent signing keys and SD-JWTs never go into source, tests, fixtures or logs.
