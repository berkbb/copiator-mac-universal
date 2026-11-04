# OpenAI Harmony Response Format Standard (`openai_harmony_response_format.md`)

> **Upstream Source:** <https://github.com/openai/harmony> (release record: repository tags and PyPI `openai-harmony`)
> **Version / Date:** `openai-harmony` 0.0.8, released 2025-11-05 (tag `v0.0.8`; GitHub Releases lists no entries)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Copiator requirements rewritten for the local model servers it can talk to.

---

## Upstream Summary

- Harmony is the response format for OpenAI's open-weight gpt-oss models. The README says gpt-oss should not be used without it, because the models will not work correctly. Inference providers such as Hugging Face, Ollama and vLLM apply the format for the caller.
- Messages carry the roles system, developer, user and assistant, each wrapped in `<|start|>` and `<|end|>` tokens.
- There are three channels: `analysis` (chain of thought), `commentary` (tool-calling preambles) and `final` (regular responses). Every message must name its channel.
- Tools are declared in the developer message under a namespace, using TypeScript-style definitions. Calls to them go to the `commentary` channel.
- The library renders and parses the format. Its core is written in Rust, it has Python bindings, and it is licensed Apache-2.0.

## Core Requirements

1. **No Harmony Renderer in the Repository:** Copiator renders no Harmony prompts. When the user picks a gpt-oss model in Ollama or LM Studio, the local server applies its own chat template; Copiator sends ordinary chat messages to 127.0.0.1, drops `<think>` sections from the reply, and validates the answer like any other model's (`LocalModelServer`, `Suggestions`). Do not add `openai-harmony` or any other renderer to `Package.swift` or `Scripts/`.
2. **Reasoning Is Not an Answer:** Analysis or reasoning text from any model is never shown as a suggestion or applied; only the validated final answer counts.
3. **If a gpt-oss Agent Is Used Later:** Its `commentary` tool calls follow the same consent rules as any other tool call (`model_context_protocol.md`, `openai_model_spec.md`). Formatting is left to the inference provider.
