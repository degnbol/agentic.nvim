# Plan: tell the agent its context usage past a threshold
Status: reviewed spec
Priority: P3

## Relevant files
- `lua/agentic/session_manager.lua` — `usage_update` branch of
  `_on_session_update` (stores `self._usage`), `_handle_input_submit_inner`
  (assembles the prompt's context blocks), `_update_chat_header` (the `Nk`
  header figure), `create_session` callback (`self._is_first_message = true`)
- `lua/agentic/environment_info.lua` — model for a prompt context block
- `lua/agentic/ui/info_panel.lua` — usage formatters (`context_totals`)
- `lua/agentic/config_default.lua`, `doc/agentic.txt` (`*agentic-config-*`)
- `lua/agentic/session_manager.test.lua`
- Skills: `session-lifecycle`, `provider-system`; rules: `tests.md`, `help.md`

## Background
Agent performance degrades past ~200k tokens of context, whatever the
model's window. An agent that knows its usage can choose at decision
points: hand new work to a subagent, write a plan or handover instead of
implementing, or wrap up. Below the threshold the number is noise.

The plugin already has the number for every provider: `usage_update.used`
arrives from claude-agent-acp (after each assistant message, each result,
and at a compaction boundary with the post-compaction count) and from
opencode (at turn end), and `_update_chat_header` shows it to the user. The
model never sees it. Building this in the plugin makes it provider-neutral;
a Claude Code hook would cover Claude only and would reparse the transcript
JSONL for a number the plugin already holds.

`<context_usage>` goes in its own text block before the user text, like
`<environment_info>`, which is sent with the first prompt only, so it
cannot carry this. Slash commands get no context blocks (opencode joins all
text blocks to find the leading `/`).

The guidance is sent once per crossing; later prompts carry only the
number. A prompt sent below the threshold re-arms the guidance, so after
compaction the next crossing gets it again, as the compaction summary may
have dropped the earlier copy.

The guidance names the configured threshold, not a fixed figure, so it
stays true when the user changes the option.

## Changes
- `config_default.lua`: `--- @type integer|false` option
  `context_usage_threshold = 150000` — used-token count from which user
  prompts carry `<context_usage>`; `false` disables. Help entry
  `*agentic-config-context_usage_threshold*` in `doc/agentic.txt`.
- `ui/info_panel.lua`: `InfoPanel.tokens_k(used: integer): string` →
  `"172k"`. `_update_chat_header` uses it instead of its inline rounding.
- New `lua/agentic/context_usage.lua`:
  - `M.build(used: integer, threshold: integer, guidance: boolean): string`
    — `<context_usage>Context usage: 172k tokens.</context_usage>`; with
    `guidance`, adds: `Past <threshold>k, agent performance degrades.
    Before starting new work, prefer handing it to a subagent, writing a
    plan or handover doc instead of implementing, or wrapping up.`
- `session_manager.lua`:
  - Field `--- @field _context_guidance_sent? boolean The context-usage guidance went out since usage last fell below the threshold`.
  - `SessionManager:_take_context_usage(): string|nil` — nil when the
    threshold is `false` or `self._usage` is nil; when `used` is below the
    threshold, also clears `_context_guidance_sent`. Otherwise returns
    `ContextUsage.build(used, threshold, not self._context_guidance_sent)`
    and sets `_context_guidance_sent`.
  - `_handle_input_submit_inner`: inside `if not is_command`, after the
    `<environment_info>` block, insert a text block with
    `self:_take_context_usage()` when non-nil.
  - `create_session` callback, next to `self._is_first_message = true`:
    `self._usage = nil`, `self._context_guidance_sent = nil`. This covers
    every new ACP session, including `switch_provider`, which bypasses
    `_reset_conversation` and today keeps the old provider's figure in the
    header.
  - `usage_update` branch: ignore updates whose `source_session_id` is set
    and differs from `self.session_id`, as the `config_option_update`
    branch does. A subagent's child-session figure must not replace the
    root's.
- Tests:
  - `lua/agentic/context_usage.test.lua`: with and without guidance;
    threshold rendered in `k`.
  - `info_panel` test for `tokens_k` rounding.
  - `session_manager.test.lua`, new `describe` driving
    `_handle_input_submit_inner` and inspecting the sent prompt (as the
    cases near :7057): below threshold → none; first crossing →
    guidance; next prompt → number only; a prompt below then above →
    guidance again; slash command → none; `<context_usage>` precedes the
    user text; `false` threshold → none; child-session `usage_update` does
    not change `_usage`.

## Expected outcome
User prompts sent at or above 150k carry `<context_usage>`: with
the guidance on the first, the number alone after that. Below 150k, and for
slash commands, nothing changes. Works for every provider that sends
`usage_update`. The header no longer shows a figure from a previous
provider or from a subagent.

Accepted gaps: no `<context_usage>` on the first prompt of a session before its first
`usage_update` (fork, re-create from history, load/resume, provider
switch), though a history prefix can make that prompt large; and a refused
or limit-returned prompt that is resubmitted carries the number only, as
its guidance was already taken.

## Non-goals
- Mid-turn polling. Opencode reports usage only at turn end, so a poll
  inside a long turn would be stale for it; one provider-neutral
  `<context_usage>` at turn start covers the decision points.
- Background sessions (`BackgroundSession`) and synthetic prompts: own
  prompt paths without context blocks.
- Sessions outside agentic.nvim (Claude Code TUI).
- Estimating the size of a history prefix before the first `usage_update`.
