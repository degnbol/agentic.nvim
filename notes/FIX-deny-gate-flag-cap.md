# Plan: exact multi-element positional matching (remove the flag cap)
Status: reviewed (open questions)

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — `MULTI_ELEMENT_FLAG_CAP`, `absorbable_flag_count`, `some_stream_matches`, `gate_matches_existential`, `every_stream_matches`, `deny_leaf`, `decide_leaf`, `classify_leaf`
- `lua/agentic/utils/permission_structured.test.lua` — `describe("deny_leaf")`
- `lua/agentic/utils/permission_rules.lua` — `command_is_denied`, `should_auto_reject`, the approve walk's `decide_leaf` call
- `lua/agentic/ui/permission_manager.lua` — `PermissionManager:decide` returns `"deny"` on `should_auto_reject` before any prompt
- `.claude/skills/permissions/references/parsing.md` — § "Arity — absorption parses", existential bullet
- `notes/bug-deny-gate-flag-cap.md` — the audit report this plan replaces
- Skills: `permissions` (project), `implement`

## Background
`gate_matches_existential` returns `true` for a gate with 2+ `positionals` when `absorbable_flag_count` exceeds `MULTI_ELEMENT_FLAG_CAP = 24`. The cap's docstring says this "only over-prompts". That holds for `decide_leaf` and `classify_leaf` (highlight only): the approve walk collapses `"deny"` and `"ask"` to "not approved → prompt" (comment at the `decide_leaf` call in `permission_rules.lua`). It does not hold for `deny_leaf`, which uses the same existential matcher in the reject pass: `should_auto_reject` → `PermissionManager:decide` returns `"deny"` with no prompt.

Demonstrated with `nvim --headless -l` against the current code, entry
`tool = { deny = {{ positionals = {"danger","now"} }}, read_only = {{ positionals = {"safe","*"} }} }`,
args `-x v1 … -x vN safe file`:

| N  | `deny_leaf` | `decide_leaf` |
|----|-------------|---------------|
| 24 | false       | nil           |
| 25 | true        | "deny"        |

At N=25 the command never contains `danger now` but is rejected without a prompt.

Allow side: `gate_matches_universal` has no cap. `every_stream_matches` memoises on `(i, pos, state_key)`, so it is polynomial and exact. Over 24 flags an allow gate is evaluated normally; it is not affected.

Bundled rules (`lua/agentic/permissions.json`) have no multi-element `deny` gate (26 multi-element `ask`, 50 `read_only`), so the reject bug is reachable only through `Config.permissions.structured`. Bundled multi-element `ask` gates over the cap force a prompt today. Exact matching stops that for commands whose parses never expose the gated stream. This is intended: the cap's docstring gives cost as its only purpose, and the audit's "fall back to asking" (`bug-deny-gate-flag-cap.md` § Expected) describes the cap's fallback, which the memo makes unnecessary.

Root cause: the cap exists because `some_stream_matches` is an unmemoised DFS. Its cost is about C(#absorbable flags, #patterns − 1), not 2^#flags: an absorb-0 branch dies at once unless the flag's value matches the next pattern element. Measured without the cap: 200 `-x v` pairs with gate `{danger, now}` take 2 ms; `-x a` pairs with gate `{*,*,*,*,*,*,b}` and tail `x` take 21 ms at 20 pairs, 2.8 s at 40. `rec(i, pos)` is a pure function of `(i, pos)` — `patterns`, `words`, `dynamic`, `dashdash_value`, `n`, `nw` are fixed for the call, and the `--` branch only mutates its own `pos` parameter. A memo on `(i, pos)` bounds the work to O(#words × #patterns) states, plus one O(#words) scan per `--` state. Measured with the memo: the 7-element case takes 0.9 ms at 200 pairs; 5000 `-x v` pairs take 6 ms.

Rejected alternative: keep the cap and make the over-cap path return "unknown" so `deny_leaf` falls through to the approve walk's prompt. It is fail-closed but keeps an extra state and branch for a case the memo removes.

## Changes
`lua/agentic/utils/permission_structured.lua`
- Delete the `-- ponytail` comment, the docstring and `MULTI_ELEMENT_FLAG_CAP`.
- Delete `absorbable_flag_count`; it has no other callers.
- `some_stream_matches`: add a memo table local to the call, keyed on `i` and `pos`; `rec` reads and writes it. Test the cache with `memo[key] ~= nil` (as `every_stream_matches` does) so `false` results are cached; a `memo[key] or …` lookup re-runs every false state and keeps the blow-up. Signature unchanged. Docstring: replace "DFS over each flag's 0/1 absorption" with a note that the search is memoised on (word index, pattern index).
- `gate_matches_existential`: remove the over-cap `elseif` branch; the multi-element case calls `some_stream_matches` directly.

`lua/agentic/utils/permission_structured.test.lua` — in `describe("deny_leaf")`:
- A multi-element deny gate `{danger, now}` with 30 `-x vN` pairs before a non-matching stream (`safe file`): `deny_leaf` is false, `decide_leaf` is not `"deny"`. (Fails today through the cap.)
- The same 30 pairs before `danger now`: `deny_leaf` is true (exact match still rejects).
- Deny gate `{"*","*","*","*","*","*","b"}`, 200 `-x a` pairs, tail `x`: `deny_leaf` is false. This is the shape that blows up without the memo (C(200,6) branches); `-x vN` pairs do not, because an absorb-0 branch dies at the first non-matching value. mini.test has no per-case timeout, so a regression shows as a hang.

`.claude/skills/permissions/references/parsing.md`, existential bullet: "enumerates parses (bounded)" → "searches parses (memoised)". The next sentence, "An over-match only over-prompts", is false for `deny_leaf` regardless of the cap (Open question 1); its rewrite depends on that answer.

When this lands, delete `notes/bug-deny-gate-flag-cap.md` and its entry 0.13 in `notes/audit-edge-cases.md`.

## Expected outcome
- Multi-element `deny` and `ask` gates match exactly at any flag count. A command whose parses never expose the gated stream is not rejected and not forced to prompt by these gates.
- A command that does expose it is still rejected (deny) or prompted (ask).
- Allow behaviour unchanged.
- Matching time for multi-element gates is polynomial in the word count.

## Non-goals
- Single-element positional, `options` and `leading_options` matching (already linear, no cap).
- `FOR_UNROLL_CAP` and other walker caps in `permission_rules.lua`.
- Recursion depth. The matchers recurse once per word, and `ZshParse.MAX_SOURCE_BYTES` (65536 chars, checked in `ZshParse.parse_command`) bounds length, not depth. Measured today with `-a` flags before `safe file`: `decide_leaf` overflows the Lua stack at about 4000 words (in `every_stream_matches` via `vim.iter`, even for a one-element allow gate); `deny_leaf` overflows at about 20000. With the cap removed, `deny_leaf` overflows on 13000 `-x a` pairs, but `decide_leaf` already overflows on that command. So this plan adds no new failing input to `PermissionManager:decide`, and making only `some_stream_matches` iterative would not fix depth. The depth problem needs its own bug note. Its effect: the ACP path (`ACPClient:__handle_request_permission`) notifies an error and answers `cancelled`; the hook path (`permission_hook.lua` `M.evaluate`) logs only through `debug_to_file` and returns undecided, so the SDK auto-mode classifier decides and can approve.

## Open questions
1. Existential reject on flag-value absorption. `deny_leaf` fires when *some* absorption parse exposes the stream: `tool -x danger now` is rejected with no prompt by deny `{danger, now}` (verified against the current code), although the parse where `-x` takes `danger` runs `now`. The `deny_leaf` docstring says a maybe-deny must fall through to the prompt (the same reason it keeps `--` after a flag as end of options), and `parsing.md:27` says an over-match only over-prompts. The cap bug is one instance of this. Options: (a) keep existential deny for the reject pass, and fix only the cap here; correct the docstring and `parsing.md`; (b) make the reject pass require the stream in every parse (the universal matcher), so a maybe-deny prompts; `decide_leaf` keeps existential deny/ask. (b) would supersede most of this plan for `deny_leaf`.
