# Agentic Commerce Protocol Standard (`agentic_commerce_protocol.md`)

> **Upstream Source:** <https://agenticcommerce.dev> (specification repository: <https://github.com/agentic-commerce-protocol/agentic-commerce-protocol>)
> **Version / Date:** Beta; latest stable specification `2026-04-17` (from the repository README; the canonical page states no version)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; recorded as a boundary rule only (Copiator sells nothing).

---

## Upstream Summary

- Stripe and OpenAI developed ACP, an open standard licensed Apache 2.0, so that any compatible agent can start a checkout with a business that implements it.
- Delegated payment passes credentials to agents without exposing the underlying payment credentials. Stripe's Shared Payment Token is the first compatible option.
- Checkout can be published through a traditional API or MCP. Versions are date-based (`YYYY-MM-DD`), and the `2026-04-17` release covers cart, feed, orders, authentication and MCP.
- Not stated on the canonical page, so not adopted here: order events (the repository README names only "orders").

## Core Requirements

1. **No Commerce in Copiator:** Copiator is free GPL-3.0-only software; it sells nothing and has no checkout, product feed or payment handling. Adding ACP endpoints, SDKs or payment code needs an explicit user decision first.
2. **Never Transact for the User:** Agents never enter payment details, make purchases or accept terms. Any purchase needs the user's explicit confirmation of the item and the total before it happens.
3. **Payment Tokens Are Secrets:** Shared Payment Tokens or other delegated credentials never go into source, tests, fixtures or logs.
