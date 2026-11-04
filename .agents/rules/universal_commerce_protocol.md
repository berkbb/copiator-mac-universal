# Universal Commerce Protocol Standard (`universal_commerce_protocol.md`)

> **Upstream Source:** <https://ucp.dev> (specification: <https://ucp.dev/latest/specification/overview/>; releases: <https://github.com/Universal-Commerce-Protocol/ucp>)
> **Version / Date:** Specification `2026-08-25` (latest GitHub release `v2026-08-25`; the specification overview references `https://ucp.dev/2026-08-25/specification/overview/`)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; recorded as a boundary rule only (Copiator has no commerce).

---

## Upstream Summary

- UCP is an open standard for agentic commerce. Its shopping co-developers are Google, Shopify, Etsy, Wayfair, Target, Walmart, Amazon, Microsoft, Meta, Salesforce and Stripe. Lodging and food have their own co-developer lists.
- Its capabilities are catalog, cart, checkout, identity linking (OAuth 2.0), order (post-purchase status, tracking and returns via webhooks), and lodging booking as a draft specification.
- UCP has built-in support for AP2 (payments), A2A (agent interoperability) and MCP (tools and context), over REST and JSON-RPC transports.
- Businesses publish a profile at `/.well-known/ucp`. When negotiation fails, `continue_url` sends the buyer to the business's standard web checkout.
- Not stated on the canonical page, so not adopted here: that Google and Shopify "lead" UCP (the page lists all of them as co-developers).

## Core Requirements

1. **No Commerce in Copiator:** Copiator has no catalog, cart, checkout, orders or payments. Adding UCP or a `/.well-known/ucp` profile needs an explicit user decision first.
2. **Never Transact for the User:** Agents never enter payment details, link identities, make purchases or accept terms. Any purchase needs the user's explicit confirmation of the item and the total.
3. **Credentials Stay Out of the Repository:** OAuth tokens from identity linking and all payment credentials never go into source, tests, fixtures or logs.
