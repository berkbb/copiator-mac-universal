# Agent Skills Specification Standard (`agent_skills_specification.md`)

> **Upstream Source:** <https://agentskills.io/specification> (validator: `skills-ref` in `agentskills/agentskills`)
> **Version / Date:** The page shows no version number; content as published on 2026-11-03
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten for the three existing skills.

---

## Upstream Summary

- A skill is a directory with a required `SKILL.md`: YAML frontmatter followed by Markdown instructions. Optional `scripts/`, `references/`, and `assets/` directories hold code, documentation, and static resources.
- Frontmatter: `name` (required, 1–64 characters, lowercase `a-z`, `0-9`, and hyphens, no leading, trailing, or consecutive hyphens, must match the directory name); `description` (required, 1–1024 characters, says what the skill does and when to use it); optional `license`, `compatibility` (1–500 characters), `metadata` (string-to-string map), and `allowed-tools` (experimental).
- Progressive disclosure: about 100 tokens of metadata load at startup, the `SKILL.md` body (under 5,000 tokens recommended, under 500 lines) loads on activation, and resources load only when needed. File references stay one level deep from `SKILL.md`.
- Validation: `skills-ref validate ./my-skill`.

## Core Requirements

1. **New Skills Use the Spec Layout:** Create new skills as `.agents/skills/<name>/SKILL.md`, with `name` equal to `<name>` and a `description` that names the task and its trigger.
2. **Existing Skills Stay Put:** `sentinel_test_skill.md`, `engine_maintenance_skill.md`, and `snapshot_audit_skill.md` are flat files without frontmatter. Migrating them renames paths that `.agents/AGENTS.md` and the global `CLAUDE.md` cite, so it happens only when the user asks.
3. **Scripts Are Existing Repo Scripts:** A skill runs the repository's own tooling (`swift test`, `Scripts/*.sh` such as `build_app.sh`, `verify_bundle.sh`, `build-rsync.sh`, `update-rsync.sh`, and `package.sh`). A skill's `scripts/` directory holds only scripts the user has approved; no ad-hoc scripts in the project tree.
4. **Stay Small:** Keep `SKILL.md` under 500 lines and move long reference material to `references/`.
5. **`allowed-tools` Is Not a Safety Boundary:** The field is experimental and its support varies by agent; the consent rules in `model_context_protocol.md` and `openai_agents_sdk_safety.md` still apply.
6. **Validation:** Run `skills-ref validate` on a new skill when the tool is available. Installing it needs the user's approval.
7. **Third-Party Skills Keep Their License:** The Graphify skill in `.claude/skills/graphify/` is installed by `graphify install --project` with its `LICENSE`, `LICENSE-MIT`, and `NOTICE` next to it (`graphify_knowledge_graph.md`); it is not edited by hand.
