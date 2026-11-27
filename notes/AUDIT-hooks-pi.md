# Audit: what each Claude Code hook becomes under pi
Status: draft
Priority: P2
Depends:

## Relevant files
- `~/dotfiles/config/claude/settings.json` `hooks` (73 commands over 62 scripts, plus 7 test fixtures), `~/dotfiles/config/claude/hooks/` (`lib/core.zsh`, `lib/checks/`, `lib/skill-paths.zsh`, `lib/ref-paths.zsh`)
- `notes/REFACTOR-pi-only.md` — step 9 (capabilities), step 10 (harness and UI, the plugin's pi package)
- pi 1.6.1 docs: `extensions.md` (§ Events), `packages.md`; the pi package gallery
- `pi-claude-bridge` README § Hooks written for Claude Code

## Background
Under pi, hooks are pi extensions that work for any model. There is no
layer that runs the scripts listed in Claude's `settings.json`.

Many hooks are not rules of their own. They work around a limit of Claude
Code, and are hooks so that stock Claude Code keeps them: a guard that
makes the agent load a skill, because Claude Code loads skills only by
description; context saved before compaction; a bell. Under pi the limit
can be absent, or a pi feature, a pi package or one harness extension can
replace several hooks. So each hook is judged by its cause, not ported.

pi extension events cover the Claude events: `session_start`, `input`
(UserPromptSubmit; it sees `/skill:name` before expansion, so it also
covers UserPromptExpansion), `before_agent_start` (context for the run),
`tool_call` (PreToolUse; `{ block: true, reason }`), `tool_result`
(PostToolUse), `agent_before_settle` (Stop; can request one
continuation), `session_before_compact` (PreCompact), `session_compact`
(PostCompact), `session_shutdown` (SessionEnd). `ui_prompt_start` fires
when an extension UI prompt waits for the user, the nearest equivalent
of `Notification`. pi has no `CwdChanged` or subagent events.

The user-level hooks exit at once inside the bridge's Claude Code child
(dotfiles `config/claude/hooks/lib/core.zsh`).

## Changes
1. The hooks grouped by trigger and purpose, and where each group moves:
   not needed (the cause is absent under pi); pi itself or a pi package;
   the plugin's pi package (`pi/`, a mechanism any agentic.nvim user
   needs); a personal pi extension in `~/dotfiles/config/pi/extensions/`
   (the user's own rules); drop. Purposes are from the hooks'
   names and header comments; the destinations are a first reading.

   | Group | Hooks | Trigger | Cause | Moves to |
   |---|---|---|---|---|
   | Skill and reference loading | `path-skill-guard`, `ref-guard`, `cwd-skill-guard`, `mlr-skill-guard`, `probe-skill-guard`, `figure-place-skill-guard`, `debug-skill-remind`, `track-skills`, `compact-downgrade` | File tools and Bash (Pre), session start, prompt, cwd change, after compaction | Claude Code loads a skill only by its description | The mechanism (load a skill or rule when a path or command matches) to the plugin, with step 8's path-triggered rules; the path-to-skill tables (`lib/skill-paths.zsh`, `lib/ref-paths.zsh`) personal |
   | Edit record and wrap-up | `pre-edit-track`, `track-edits`, `track-reads`, `track-commits`, `edit-context`, `completion-review`, `auto-fix` | Edit/Write/Read/Bash (Pre and Post), `Skill(commit)`, before compaction, Stop | Claude Code gives hooks no record of the session's edits | The plugin: pi's session file has every tool call, so the record is read, not tracked |
   | Lint and format | `lint-post-edit`, `lint-stop`, `lint-pre-commit`, `fmt-zsh-mlr`, `json-validate`, `execute-syntax-check` | Edit/Write (Post), Stop, `Skill(commit)`, Bash (Pre) | No lint step in the agent loop | Run-a-linter-after-edit: plugin or pi package; which linters: personal. Candidate package: [`pi-lens`](https://github.com/apmantza/pi-lens) (linters, formatters and LSP diagnostics after each edit, findings in the tool result; user-level ast-grep and tree-sitter rules; no zsh grammar). `execute-syntax-check` may be covered by the permission parse |
   | Code and prose rules | `shell-guard`, `jq-guard`, `zsh-tied-var-guard`, `zsh-prefix-remove-guard`, `zsh-repo-root-guard`, `zsh-shebang-remind`, `prose-guard`, `style-guard`, `claudemd-guard`, `home-path-guard`, `dotfiles-guard`, `realpath-remind`, `swallow-remind`, `subprocess-remind`, `typst-greek-guard`, `bib-guard`, `python-import-guard`, `python-construct-remind`, `pyright-exclude-guard`, `nvim-api-guard`, `nvim-cmd-guard`, `nvim-intrinsics-remind`, `nvim-native-api-remind`, `data-edit-remind`, `hardcoded-numbers-remind`, `new-file-remind`, `playwright-remind`, `png-read-guard`, `identifier-guard-edit`, `clone-remind`, `rm-refs-remind` | File tools and Bash (Pre and Post), prompt | The user's own rules | Personal |
   | Reply checks | `apology-guard`, `identifier-guard`, `bracket-guard` | Stop | The user's own rules | Personal |
   | Session | `bell`, `session-cleanup`, `cwd-remind`, `auto-mode-remind`, `gitignore-guard`, `webfetch-guard` | Notification, Stop, session start and end, cwd change, prompt, Grep/Glob, WebFetch | Claude Code specifics | `bell`: not needed (the plugin rings). `auto-mode-remind`: drop. `cwd-remind`: no pi event. The rest when a plan needs them |
   | Test fixtures | `hooks/tests/fixtures/*` | Write to `/tmp/hook-ch-probe.md` | Hook output tests | Drop |
2. Single hooks are decided when their group's extension is planned, one
   plan per extension.

## Expected outcome
- Each group has a destination.

## Non-goals
- Running Claude's `settings.json` hooks in pi.
- A decision for each single hook.

## Open questions
