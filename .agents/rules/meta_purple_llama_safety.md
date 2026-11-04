# Meta Purple Llama Agentic Safety Standard (`meta_purple_llama_safety.md`)

> **Upstream Source:** <https://github.com/meta-llama/PurpleLlama> (Llama Guard 4, LlamaFirewall, Prompt Guard 2, CyberSecEval 4)
> **Version / Date:** 2026 Stable
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set (formerly `meta_fair_safety.md`), whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Copiator requirements rewritten.

---

## Core Requirements

1. **Credential & Personal Data Firewall:** Every sandboxed rsync run denies reads of `SandboxProfile.personalDataDirectories` (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.kube`, `~/.docker`, package-manager and cloud credentials, shell histories, `~/Library/Keychains`, Cookies, Mail, Messages, `Containers`, `Group Containers`, browser profiles, and more). A source inside one of those folders opens only that source, never the whole protected folder, and a larger source copies with those folders excluded. The rule scanner never enters protected folders while the sandbox is on.
2. **Prompt Injection Through Files:** File names, folder names, and the text Copiator reads from PDFs and plain files for suggestions are untrusted data. A model answer is accepted only when it names an offered candidate folder or a template whose tokens are known and that reproduces the examples; anything else is discarded, and nothing is applied without the user's action (`AGENTS.md` invariant 22). Prompts never contain an example answer a model could copy.
3. **Deceptive Names & Risky Paths:** `OpenSafety.visibleName` shows bidirectional overrides and invisible fillers as `⟦U+XXXX⟧` in every view that shows a path, and placement and chosen folders never leave the destination (`PlacementResolution.clean`, `RoutePlacement.component`).
4. **Resource Exhaustion:** Sizes are summed with saturating arithmetic (`math_rules.md`), free space is checked before copying and watched while copying (`DiskSpace`, `DiskSpaceGuard`), `CommandRunner.maxOutputBytes` stops a run whose output would exhaust memory, regular expressions stop at `RuleEvaluator.regexStepBudget`, and every model call ends at `Suggestions.timeout`.
