# Plan: tidy the `acp` skill's claude-agent-acp reference
Status: draft
Priority: P3

Target: `~/dotfiles/config/claude/skills/acp/references/claude-agent.md`
(global skill, dotfiles repo). Findings from a prose review; the small
fixes (version stamps, minified names, the fixed conditional-skills bug,
the subagent section) are done.

## Changes
- **Line numbers to symbols.** The file's own rule (§ Source locations:
  "grep the quoted symbol, line numbers move every release") is broken at
  `sdk.d.ts:NNNN` references throughout, `acp-agent.js` `:2051`/`:2107`
  (§ hook events), `:600-609`/`:449-450`/`:615` (§ Prompt loop stall),
  `:1366-1369` (§ ConfigOptions), `acp.js:1146-1161`. Replace each with
  the type, function or symbol it points at, found in the installed
  bridge and SDK.
- **Reorder peers.**
  - § Slash command recognition uses the last text block next to
    § Probing advertised slash commands.
  - § Edit tool and § Search tools after § Tool call notifications, before
    the two subagent sections.
  - § Environment variables, § settings.json paths and § Path-scoped rules
    next to § Session creation via `_meta` passthrough.
  - § Known SDK bugs now holds only non-bugs (additionalWorkingDirectories,
    edits not applied before permission): retitle or fold them into the
    sections they qualify. § Prompt loop stall becomes a top-level peer.

## Non-goals
- Re-verifying claims outside § Native subagent sessions.

## Open questions
None.
