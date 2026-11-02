# PLAN: show when a hook rewrote a tool call's input

Status: reviewed (open questions)

## Background

A `PreToolUse` hook can return `hookSpecificOutput.updatedInput`, which replaces
the whole tool input before the tool runs. The chat renders the input the model
sent, so after a rewrite the displayed input is not the input that ran. The hook
rows (`MessageWriter:write_hook_block`) show hook activity, not the rewritten
input.

### Input path over ACP

claude-agent-acp sends the model's input, never the rewritten one:

- `tool_call` / `tool_call_update` `rawInput` comes from the assistant
  `tool_use` chunk (`dist/tool-calls/renderer.js`).
- The PostToolUse hook callback gets the post-rewrite `tool_input` and discards
  it (`onPostToolUseHook: async (toolUseId, _toolInput, toolResponse)` in
  `dist/acp-agent.js`).
- A `session/request_permission` carries the `canUseTool` input
  (`dist/permissions/presentation.js`), which is post-hook. A hook that also
  returns `permissionDecision: "allow"` skips `canUseTool`, so then no request
  is sent.

So the divergence is real, and the client has no source for the rewritten
input except a permission request. A client cannot read a user hook's output.

### Rewrites in the transcript history

Every `hook_success` record with `updatedInput` under `~/.claude/projects/`,
compared against its `tool_use` input:

| Hook | Tool | Records | Change |
|---|---|---|---|
| `hooks/subagent_hook.lua` (this plugin, `subagents.force_background`) | Agent | 512, plus 88 no-ops | sets `run_in_background = true` |
| `~/.config/claude/hooks/shell-guard.sh` | Bash | 83 | prefix `PYTHONUNBUFFERED=1 `; drops `description` (and `timeout` in 19) |

- The shell-guard rewrite no longer exists: dotfiles commit 523fa358 removed
  it, and `config/claude/settings.json` sets `PYTHONUNBUFFERED` instead. No
  hook in `config/claude/` returns `updatedInput`.
- All Bash rewrites were pure prefixes. The dropped `description`/`timeout`
  show `updatedInput` replaces the object, it does not merge.
- The only live rewriter is this plugin's `subagent_hook.lua`. The chat does
  not render `run_in_background` (declared in `claude_agent_acp_adapter.lua`,
  read nowhere), so that rewrite causes no visible divergence.

## Changes

None until the open question is answered. For an additive command rewrite, the
minimal treatment is an extmark over the inserted span linked to
`Theme.HL_GROUPS.DIFF_ADD` (`AgenticDiffAdd`); priority against treesitter on a
fenced execute command is covered by the `rendering` skill. It needs the
rewritten input from the bridge first.

## Open questions

- Scope Q: no live hook rewrites a field the chat shows. Retire this plan, or
  keep it for future user hooks (which needs a bridge change to send the
  rewritten input)?
