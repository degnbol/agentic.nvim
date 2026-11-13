# Plan: opencode child-call titles without the subagent prefix
Status: reviewed spec
Priority: P2

## Relevant files
- `lua/agentic/acp/adapters/opencode_acp_adapter.lua`, `.test.lua`
- `.claude/skills/provider-system/SKILL.md` § "opencode kind remapping"
- opencode v2.2.5 `packages/cli/src/acp/child.ts` (`project`, `meta`,
  `prefixTitle`), `translate.ts` (`route`), source at `/tmp/opencode-src`

## Background
A subagent's tool calls reach the parent session's stream with
`_meta["opencode/child-session"] = {id, parentID, depth, title?}` on every
update, and `title`, when present, rewritten to `<child title>: <title>`
(`child.ts` `project`). The prefix and the meta `title` come together; a
nested child gets one prefix, from the nearest child. Shell calls are
prefixed too (their title is the command, or `shell`). A `completed`
update has no `title`, but still has the meta.

A `tool_call_update` has no `name`, so its title is the only tool identity
the adapter has. With the prefix, `title == "grep"`/`"glob"` never matches:
a child search head shows the prefixed title (`Explore x: grep`) and never
the `rg` command. Stripping the known prefix recovers the tool's own title
deterministically, from the same meta that caused it.

## Changes

### `opencode_acp_adapter.lua`
- New local:

  ```lua
  --- The call's title without the `<child title>: ` prefix opencode adds to
  --- a subagent's calls (`_meta["opencode/child-session"].title`).
  --- @param update agentic.acp.OpenCodeToolCallMessage|agentic.acp.OpenCodeToolCallUpdate
  --- @return string|nil title
  local function tool_title(update)
  ```

  nil title → nil. Returns `update.title` unchanged when the meta has no
  `title` or the title does not start with `<meta title>: `
  (`vim.startswith`, not a pattern).
- `__handle_tool_call_update`: `input_fields(tool_title(update), update)`
  instead of `input_fields(update.title, update)`.
- `__handle_tool_call`: the default argument compares and uses
  `tool_title(update)` instead of `update.title`, so every call's head is
  built from the same title whichever session made it.

### `provider-system` SKILL.md
- Extend the 2.x plan's sentence: `tool_call` dispatches on `name`;
  updates, which carry no `name`, on the title with the child prefix
  stripped.

### `opencode_acp_adapter.test.lua`
All updates set `status` (the hook ignores status-less updates).
- In-progress child grep: `kind = "search"`, `title = "Explore x: grep"`,
  `_meta = {["opencode/child-session"] = {title = "Explore x"}}`,
  `rawInput = {pattern = "foo"}` → argument `rg "foo"`.
- Completed child update: meta `title`, no `title` → no error.
- Meta `title` present, title without the prefix → title used unchanged.
- No meta, `title = "a: grep"` → left as is (not stripped).
- Child shell: `title = "Explore x: ls"`, `rawInput = {command = "ls"}` →
  argument `ls`.

## Expected outcome
A call renders the same whichever session made it: grep/glob calls show the
formatted `rg` command while they run, and no head carries a session prefix.

## Non-goals
- Child-session calls in subagent transcripts:
  `FEAT-opencode-subagent-transcripts.md`, which builds on this plan.
- Opting in to `opencode/session/child_update` notifications.

## Open questions
None.
