# Stanford Generative Agents Memory Reflection Standard (`generative_agents_reflection.md`)

> **Upstream Source:** <https://github.com/joonspk-research/generative_agents> — paper "Generative Agents: Interactive Simulacra of Human Behavior", Joon Sung Park, Joseph C. O'Brien, Carrie J. Cai, Meredith Ringel Morris, Percy Liang, Michael S. Bernstein (<https://arxiv.org/abs/2304.03442>)
> **Version / Date:** arXiv v2, 2023-08-06 (v1 2023-04-07); UIST '23 per the repository README; the repository has no tagged releases
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten.

---

## Upstream Summary

- The architecture keeps a complete natural-language record of an agent's experiences (the memory stream), synthesizes those memories into higher-level reflections over time, and retrieves them dynamically to plan behavior.
- Retrieval scores each memory as a weighted sum of recency (exponential decay since last access), importance (a 1–10 rating given when the memory is created), and relevance (embedding cosine similarity to the current query).
- Reflection is periodic, not per event: it runs when the summed importance of the latest events passes a threshold (150 in the implementation). A stored reflection keeps pointers to the memories it cites, and reflections can build on other reflections.
- In the paper's ablation, observation, planning, and reflection each contributed critically to believable behavior.
- Not stated on the canonical page, so not adopted here: a "genagents" 2024 follow-up. The separate `joonspk-research/genagents` repository cites a 2024 paper ("Generative Agent Simulations of 1,000 People") but does not call itself a follow-up, and the canonical README does not link it.

## Core Requirements

1. **Episodes Stay Where They Are:** Single outcomes and lessons keep going into `reflexion_memory_log.md` in its existing numbered `## Episode N:` format. This file only adds the reflection layer above them.
2. **Reflect on a Trigger:** Write a reflection when at least three episodes share a root cause (for example rsync output or exit-code surprises, `sandbox-exec` path resolution, model answers that copy the prompt, or tests that miss a guard) or when the user asks; not after every task.
3. **Cite the Evidence:** A reflection names the episode numbers it is drawn from and states one higher-level lesson. A reflection that cites no episode is not recorded. Reflections go in a `## Reflections` section at the end of the log.
4. **Promote, Don't Duplicate:** When a reflection becomes a standing rule, it moves into the file that owns the topic (`ui_rules.md`, `math_rules.md`, `domain_wiki.md`, a skill) and the log keeps a one-line pointer. Changes to `.agents/AGENTS.md` invariants need the user's approval.
5. **Retrieve Selectively:** The log held 51 episodes (217 lines) on 2026-11-04. Before a task, read the episodes that name the module or symbol being changed, the most recent episodes, and any about data safety (sandbox, `--delete`, Trash, snapshots, same-name files, personal data in tests), instead of the whole file once it grows.
