# Idea: editing guidance for every provider

User-level editing guidance (per-language conventions, prose
discipline) lives in skills and skill references. Under Claude Code,
PreToolUse hooks point to them when the model Reads a matching file
and deny edits until they are loaded; the path tables are
`~/.claude/hooks/lib/skill-paths.zsh` and `ref-paths.zsh`. Project
`.claude/rules/*.md` with `paths:` frontmatter still auto-attach on
Read (mechanism in `.claude/skills/acp/references/claude-agent.md §
"Path-scoped rules"`). Non-Claude providers (Codex, Gemini, opencode,
Mistral) inherit nothing from `~/.claude/` and get neither.

Consider reimplementing client-side in agentic.nvim: watch
`tool_call`/`tool_call_update` events for read and edit kinds across
all providers, match the target path against the same tables, and
inject the pointer or hold the edit. The skills themselves already
reach non-Claude providers via the Skill tool.

For Claude specifically the hooks already fire, so the gate should be
"skip if provider is Claude (any harness)" — duplicating the injection
would double the content.

## Open questions

- table source: parse the zsh tables, or move them to a format both
  read (TSV, JSON)
- scope: the hook tables only, or also project `.claude/rules/`
  (`paths` CSV / YAML array, brace expansion, `ignore`-style globs)?
- dedup: once per session per pointer, matching the hooks
- injection point: tool result, system reminder, or user message —
  pick the one that survives compaction and isn't lost across
  cross-model resume
- interaction with the existing `read_only_commands` /
  `read_only_commands_deny` config patterns: rules are content not
  policy, so probably separate
