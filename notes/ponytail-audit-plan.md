# Ponytail audit — follow-up

The original audit (Tier 1–3) is done and committed-pending. Net ~-512 lines,
0 deps. This file now holds only what was left open. Re-grep symbols before
acting — the tree moved.

## 1. Swapped docstring in `status_animation.lua` — trivial fix

- **Where:** `lua/agentic/ui/status_animation.lua`, the doc comment above
  `is_active`.
- **What:** the docstring reads "Move the extmark to the current buffer
  bottom without changing state. No-op if no animation is active." — that
  describes `reposition`, the function *below* it, not `is_active`. They look
  swapped: `is_active` just returns a boolean.
- **Do:** move the "Move the extmark…" doc onto `reposition`; give `is_active`
  a one-line "Whether a status indicator is currently rendered." Pure docs, no
  code change. `make validate`.

## 2. Adapter `__handle_tool_call` skeleton — investigate, likely keep

Supersedes the original audit's item 2, which was **wrong**: it claimed
`claude_acp_adapter` / `opencode_acp_adapter` delegate to the base
`__build_tool_call_message` and that auggie should "match that shape." They do
not — all three adapters fully hand-build the `ToolCallBlock` in their own
`__handle_tool_call` and never call the base builder. Auggie is not rebuilding
to override one field.

- **Where:** `lua/agentic/acp/adapters/{auggie,claude,opencode}_acp_adapter.lua`,
  each `__handle_tool_call`; base `ACPClient:__build_tool_call_message` /
  `__handle_tool_call` in `acp_client.lua`.
- **Real observation:** auggie and claude share a `kind`-dispatch skeleton —
  the `read`/`edit` (smart-path + diff), `fetch` (`__resolve_fetch_fields`),
  and `else` (command-string) branches are near-identical. Claude adds
  SubAgent / Skill / SlashCommand / switch_mode cases on top; opencode
  dispatches on `update.title` instead of `kind` and is structurally
  different.
- **Why this is NOT a clean cut:** collapsing the shared branches into a base
  helper is a *net addition* (new shared method + three call sites rewired),
  touches three providers at once, and the `tool_call`/`tool_call_update`
  two-phase flow means a regression here silently drops rendering. The
  divergence is genuine provider behaviour, not copy-paste bloat.
- **Decision gate:** only worth it if auggie and claude's overlapping branches
  are *byte-identical* after ignoring claude's extra `elseif` cases. Diff them
  first. If they differ (e.g. claude's `suppress_placeholder_title`, auggie's
  `update.title` fallbacks), leave both and add a one-line comment on auggie
  noting it intentionally mirrors claude's dispatch minus the Claude-only
  kinds. Do **not** factor opencode in — different dispatch axis.
- **If you proceed:** extract only the shared `read`/`edit`/`fetch`/`else`
  body as a base method that fills a passed-in `message` table; claude calls
  it then layers its extra cases; auggie calls it bare. Adapter tests exist
  (`*_acp_adapter.test.lua` if present, else the provider-system integration
  tests) — run them. Verify a real edit still renders a diff and a real read
  still shows a smart path.

`make validate` after each change.
