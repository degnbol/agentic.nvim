# Plan: exact multi-element positional matching (remove the flag cap)
Status: blocked on clarification (Open questions 1-3)

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — matcher (cap, existential and universal stream match, `deny_leaf`, `decide_leaf`, `classify_leaf`)
- `lua/agentic/utils/permission_structured.test.lua` — matcher tests (`describe("deny_leaf")` at :1391)
- `lua/agentic/utils/permission_rules.lua` — `command_is_denied` (:2585), `should_auto_reject` (:2690), approve walk (:1350-1360)
- `lua/agentic/ui/permission_manager.lua:357-360` — reject result returns `"deny"` before any prompt
- `.claude/skills/permissions/references/parsing.md:24-27` — existential matching description
- Skills: `permissions` (project), `implement`

## Background
`gate_matches_existential` (`permission_structured.lua:516-520`) returns `true` for a gate with 2+ `positionals` when `absorbable_flag_count` (:379-395) exceeds `MULTI_ELEMENT_FLAG_CAP = 24` (:108). The comment at :102-107 says this "only over-prompts". That holds for `decide_leaf` and `classify_leaf` (:1062-1097, highlight only): the approve walk collapses `"deny"` and `"ask"` to "not approved → prompt" (`permission_rules.lua:1355-1360`). It does not hold for `deny_leaf` (:1112-1124), which uses the same existential matcher in the reject pass. `should_auto_reject` → `PermissionManager` returns `"deny"` with no prompt (`permission_manager.lua:357-360`).

Demonstrated with `nvim --headless -l` against the current code, entry
`tool = { deny = {{ positionals = {"danger","now"} }}, read_only = {{ positionals = {"safe","*"} }} }`,
args `-x v1 … -x vN safe file`:

| N  | `deny_leaf` | `decide_leaf` |
|----|-------------|---------------|
| 24 | false       | nil           |
| 25 | true        | "deny"        |

At N=25 the command never contains `danger now` but is rejected without a prompt.

Allow side: `gate_matches_universal` (:855-869) has no cap. `every_stream_matches` (:799-835) memoises on `(i, pos, state_key)`, so it is polynomial and exact. Over 24 flags an allow gate is evaluated normally; it is not affected.

Bundled rules (`lua/agentic/permissions.json`) have no multi-element `deny` gate (26 multi-element `ask`, 50 `read_only`), so the bug is reachable only through `Config.permissions.structured`. Bundled multi-element `ask` gates over the cap force a prompt today (see Open question 2).

Root cause: the cap exists because `some_stream_matches` (:409-462) is an unmemoised DFS. Its cost is about C(#absorbable flags, #patterns − 1), not 2^#flags: an absorb-0 branch dies at once unless the flag's value matches the next pattern element. Measured without the cap: 200 `-x v` pairs with gate `{danger, now}` take 2 ms; `-x a` pairs with gate `{*,*,*,*,*,*,b}` and tail `x` take 21 ms at 20 pairs, 2.8 s at 40. `rec(i, pos)` is a pure function of `(i, pos)` — `patterns`, `words`, `dynamic`, `dashdash_value`, `n`, `nw` are fixed for the call, and the `--` branch only mutates its own `pos` parameter. A memo on `(i, pos)` bounds the work to O(#words × #patterns) states, plus one O(#words) scan per `--` state. Measured with the memo: the 7-element case takes 0.9 ms at 200 pairs; 5000 `-x v` pairs take 6 ms.

Recursion depth is a separate limit. `rec` recurses once per word, and `should_auto_reject`'s length bound (`permission_rules.lua:2694`, 65536 chars) does not bound depth. Measured: `deny_leaf` overflows the Lua stack at about 20000 words of non-absorbable flags (`-a -a …`, already the case today) and, with the cap removed, at 13000 `-x a` pairs (65 KB, under the bound). Today the cap short-circuits the second shape. An overflow propagates out of `PermissionManager:decide` (no pcall); the ACP path (`acp_client.lua:996-1030`) notifies an error and answers `cancelled`, the hook path (`permission_hook.lua`) returns undecided. Neither approves, but neither prompts (Open question 3).

Rejected alternative: keep the cap and make the over-cap path return "unknown" so `deny_leaf` falls through to the approve walk's prompt. It is fail-closed but keeps an extra state and branch for a case the memo removes.

## Changes
`lua/agentic/utils/permission_structured.lua`
- Delete the `-- ponytail` comment, the docstring and `MULTI_ELEMENT_FLAG_CAP` (:102-108).
- Delete `absorbable_flag_count` (:374-395); it has no other callers.
- `some_stream_matches` (:409-462): add a memo table local to the call, keyed on `i` and `pos`; `rec` reads and writes it. Test the cache with `memo[key] ~= nil` (as `every_stream_matches` does at :819) so `false` results are cached; a `memo[key] or …` lookup re-runs every false state and keeps the blow-up. Signature unchanged. Docstring: replace "DFS over each flag's 0/1 absorption" with a note that the search is memoised on (word index, pattern index). If Open question 3 picks "iterative", write it instead as a bottom-up table over `i` from `nw` down to 1, which has no recursion depth.
- `gate_matches_existential` (:516-520): remove the over-cap `elseif` branch; the multi-element case calls `some_stream_matches` directly.

`lua/agentic/utils/permission_structured.test.lua` — in `describe("deny_leaf")`:
- A multi-element deny gate `{danger, now}` with 30 `-x vN` pairs before a non-matching stream (`safe file`): `deny_leaf` is false, `decide_leaf` is not `"deny"`. (Fails today through the cap.)
- The same 30 pairs before `danger now`: `deny_leaf` is true (exact match still rejects).
- Deny gate `{"*","*","*","*","*","*","b"}`, 200 `-x a` pairs, tail `x`: `deny_leaf` is false. This is the shape that blows up without the memo (C(200,6) branches); `-x vN` pairs do not, because an absorb-0 branch dies at the first non-matching value. mini.test has no per-case timeout, so a regression shows as a hang.

`.claude/skills/permissions/references/parsing.md:27`: "enumerates parses (bounded)" → "searches parses (memoised)". The next sentence, "An over-match only over-prompts", is false for `deny_leaf` regardless of the cap (Open question 1); its rewrite depends on that answer.

## Expected outcome
- Multi-element `deny` and `ask` gates match exactly at any flag count. A command whose parses never expose the gated stream is not rejected and not forced to prompt by these gates.
- A command that does expose it is still rejected (deny) or prompted (ask).
- Allow behaviour unchanged.
- Matching time for multi-element gates is polynomial in the word count.

## Non-goals
- Single-element positional, `options` and `leading_options` matching (already linear, no cap).
- `FOR_UNROLL_CAP` and other walker caps in `permission_rules.lua`.

## Open questions
1. Existential reject on flag-value absorption. `deny_leaf` fires when *some* absorption parse exposes the stream: `tool -x danger now` is rejected with no prompt by deny `{danger, now}`, although the parse where `-x` takes `danger` runs `now`. The `deny_leaf` docstring (:1099-1108) says a maybe-deny must fall through to the prompt (the same reason it keeps `--` after a flag as end of options), and `parsing.md:27` says an over-match only over-prompts. The cap bug is one instance of this. Options: (a) keep existential deny for the reject pass, and fix only the cap here; correct the docstring and `parsing.md`; (b) make the reject pass require the stream in every parse (the universal matcher), so a maybe-deny prompts; `decide_leaf` keeps existential deny/ask. (b) would supersede most of this plan for `deny_leaf`.
2. Bundled `ask` gates over 24 flags. Exact matching makes the 26 bundled multi-element `ask` gates stop forcing a prompt for commands with more than 24 absorbable flags whose parses never expose the stream. Is that intended, or should the over-cap case keep asking (the original report's "fall back to asking")?
3. Recursion depth. Removing the cap makes 13000 `-x a` pairs (under the 65536-char bound) overflow the stack instead of rejecting; a non-absorbable flag run already overflows at about 20000 words. Options: (a) write `some_stream_matches` bottom-up (no recursion) and leave other recursive matchers as they are; (b) add a word-count bound next to the char bound in `should_auto_reject`/`should_auto_approve` that returns "not decided" (prompt); (c) list it as a non-goal, since the overflow cancels the request with a visible error and never approves.
