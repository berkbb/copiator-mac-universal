# MCP Enterprise-Managed Authorization Extension Standard (`mcp_enterprise_managed_authorization.md`)

> **Upstream Source:** <https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization> (normative specification: `specification/stable/enterprise-managed-authorization/2026-07-28/` in `modelcontextprotocol/ext-auth`; original proposal SEP-990)
> **Version / Date:** Stable specification revision 2026-07-28; extension identifier `io.modelcontextprotocol/enterprise-managed-authorization`
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- The organization's identity provider (IdP) becomes the authoritative decision-maker for which MCP servers employees can reach, replacing per-user, per-server authorization.
- Flow: the user signs in to the MCP client through enterprise SSO; the client exchanges the stored identity assertion (OpenID ID Token or SAML assertion) at the IdP for an Identity Assertion JWT Authorization Grant (ID-JAG); the IdP evaluates policy; the client trades the ID-JAG for an access token at the MCP server's authorization server. The client does not redirect the user to that server's authorization endpoint.
- Clients declare the extension in per-request capabilities under `_meta`; extensions are opt-in and never active by default.
- Authorization servers validate ID-JAG signatures against the IdP's JWKS and check audience, issuer, and expiration; the subject claim is the primary stable user identifier. ID-JAG is defined in the IETF draft `draft-ietf-oauth-identity-assertion-authz-grant`.
- Revocation happens once at the IdP and takes effect across all MCP clients; the page lists an auditable authorization trail as a compliance reason to adopt the extension.

## Core Requirements

1. **Tokens Are Credentials:** ID tokens, SAML assertions, ID-JAGs, MCP access tokens, and `gh` tokens never go into chat, commits, job logs, test fixtures, or `.agents/` notes. A token seen in tool output is reported by location only, never quoted.
2. **A Policy Denial Is Final:** When an MCP server returns an authorization or scope error, report it and stop that path. Do not retry with another account, a personal token, or a different tool to get around the organization's policy.
3. **Access Changes Belong to Admins:** Granting or revoking server access and configuring IdP endpoints are organization-admin actions. Agents do not change client, IdP, or MCP authorization settings, and enterprise sign-in is done by the user. The same holds for the `gh` sign-in that `Scripts/release.sh` checks with `gh auth status`: the user signs in, never an agent.
4. **No Auth Code in the App:** Copiator has no accounts; its only internet calls read public GitHub release data. Adding SSO, OAuth, or JWT handling to it needs an explicit user decision first.
