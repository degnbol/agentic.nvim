# Plan: name the blocking-subagent stop by the plugin's mode
Status: spec

## Relevant files
- `lua/agentic/subagents.lua` (`mark_foreground_stopped`)
- `lua/agentic/session_manager.lua` (its one caller, `stop_generation`)
- `lua/agentic/session_manager.test.lua` (test title "reads a foreground call
  failed at the main cancel as interrupted")
- `.claude/skills/subagents/SKILL.md`

## Background
The plugin's subagent modes are `blocking` and `background`
(`SubagentMode`). "foreground" is the SDK's word for blocking. One method and
one test title use it.

## Changes
- Rename `Subagents:mark_foreground_stopped()` to
  `Subagents:mark_blocking_stopped()` and its caller.
- Test title: "foreground call" → "blocking subagent's call".
- `subagents` skill: drop the "except `Subagents:mark_foreground_stopped`"
  clause.

## Expected outcome
No behaviour change. Plugin code says `blocking` only.

## Non-goals
- `SubagentMeta.request_shape` keeps the SDK's `foreground`.

## Open questions
None.
