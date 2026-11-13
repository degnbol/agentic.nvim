# Plan: Reduce token usage
Status: reviewed
Priority: P1

Master plan. Each part below gets its own plan; link it in the part's
`Plan:` line when written. Most edits are in the dotfiles repo
(`~/dotfiles/config/claude/`), not in agentic.nvim.

## Relevant files
- `~/dotfiles/config/claude/settings.json` — hooks, model, env, plugins
- `~/dotfiles/config/claude/CLAUDE.md`, `rules/*.md`, `skills/*/SKILL.md`,
  `agents/*.md`
- `~/dotfiles/config/claude/hooks/` — `completion-review.sh`,
  `shell-guard.sh`, `gitignore-guard.sh`, `cwd-skill-guard.sh`,
  `lib/checks/*.lua`, `TODO.md` § "Distribution of work"
- `.claude/skills/provider-system/SKILL.md` (this repo)
- `lua/agentic/background_session.lua`, `lua/agentic/skeptic/init.lua`,
  `config_default.lua` (skeptic defaults)
- `~/dotfiles/config/opencode/opencode.base.json`, `opencode.json.sh`
- Skills: `claude` (+ `references/skills.md`, `hooks.md`, `subagents.md`),
  `learning`, `plan`
- Docs: https://code.claude.com/docs/en/costs, `/env-vars`, `/sub-agents`,
  `/llm-gateway-protocol`

## Background

### Measurement (2026-11-13)
Sample: the 50 most recent main-session transcripts in
`~/.claude/projects/*/*.jsonl` (subagents excluded). Tokens = bytes/4.

| Cost | Total ~tok | Note |
|---|---|---|
| Path-scoped rules | 403k | `edit-docs.md` 182k (matches every `**/*.md` read, incl. SKILL.md); lang-lua 54k; lang-zsh 41k; agentic `tests.md` 33k; edit-skill 30k |
| `implement` skill | 170k | 41 loads × 16.6 KB; the PreToolUse:Edit block forces the load. "Principles" 5.9 KB, "CLI & scripting" 4.5 KB |
| Compaction re-injects skills | 100k | 9 compactions × 44 KB `invoked_skills` |
| Other skills | ~230k | neovim 53k, provider-system 45k ("Known ACP limitations" is 16.8 of 31 KB), claude 34k, mlr 27k, commit 18k |
| Per-session fixed | ~17k/session | skill catalogue 6.9k (188 skills; 90 synced org skills, 33 from plugins), deferred MCP tools 5.4k, MCP instructions 2.2k, agent list 1.8k |
| Hooks, all | <75k injected | `completion-review.sh` 26k over 162 fires. It exits 2, so each fire also forces one extra turn, which re-reads the whole cached context. That cost is not in this number |

Hook defects found:
- Injections on every session regardless of task: `shell-guard.sh`
  bash-env ("no tty", once per session), `cwd-skill-guard.sh`, the
  xyme-snow plugin SessionStart (also on compact).
- `gitignore-guard.sh` fired on 75 of 76 Grep calls. Its `once: true` is in
  `settings.json`, where the hooks docs say `once` is ignored (honoured only
  in skill frontmatter).
- `completion-review.sh` lists "changes not by you" (e.g. `uv.lock
  +1026/-1024`, `main.pdf`) that the agent cannot act on. The shell-edit
  gap in `hooks/TODO.md` § "Edit tracking misses shell-command edits" makes
  the list larger.

Duplicates: the first two paragraphs of `rules/context7.md` (always loaded)
are the context7 MCP server instructions word for word; its `## Steps`
section is not. "~/.config is a symlink to ~/dotfiles/config" is in 5
places (dotfiles CLAUDE.md, dotfiles-guard, git_repo.lua, dotfiles skill,
claude skill § Dotfiles Layout).

### External tools
- rtk (rewrites `git status`, test and build output through a PreToolUse
  Bash `updatedInput` hook): an independent replay of 500 sessions
  (codepointer.dev) measured ~0.5% of spend saved; headroom 2.8%;
  caveman ~0.4%. Shell output is a small share of the cost above. rtk's
  hook also auto-allows, and parallel PreToolUse hooks see the original
  command, so the permission guard would check one command while another
  runs. Not adopted; part 7 measures before any adoption.
- ast-grep: maintained structural search/rewrite CLI. Fits part 6.
- Built-in levers (docs, verified by researcher): subagent frontmatter
  `model` and `effort`; `CLAUDE_CODE_SUBAGENT_MODEL`; `/effort`,
  `CLAUDE_CODE_EFFORT_LEVEL`; `BASH_MAX_OUTPUT_LENGTH` (default 30000
  chars); `/usage` shows cache misses and their causes.

### Model routing
- Claude Code has one endpoint per session (`ANTHROPIC_BASE_URL`). Sending
  subagents to LiteLLM moves the whole session onto the proxy, and the docs
  list breakage (uncached input if `cache_control` is dropped, idle
  timeouts, dropped tool fields). Routing therefore belongs in
  agentic.nvim, which already hosts sessions on several providers.
- agentic.nvim already runs opencode on `litellm/glm-5.3` and `kimi-k3`
  through `BackgroundSession` (`BackgroundSession:new`,
  `BackgroundSession:prompt`); only skeptic calls it. Nothing lets the main
  agent hand a task to it. `_set_model` sets the model; nothing sets the
  thought level.
- Subagent frontmatter supports `model` and `effort`
  (`low|medium|high|xhigh|max`). `CLAUDE_CODE_EFFORT_LEVEL` overrides both
  frontmatter and the per-call `effort`. None of `agents/*.md` sets either,
  and no effort setting or env var is set.

## Changes

Priority: P1 large measured cost; P2 moderate; P3 small or speculative.

1. P1 **Measurement script.** Plan: (to write)
   A deterministic script that reproduces the table above per session
   (rules, skills, compaction re-injection, hooks, fixed listing) from
   transcripts, so every later part is judged before/after. Use the
   transcripts' `usage` fields where present instead of bytes/4. Include
   the cost of hook-forced extra turns (`completion-review.sh`); if large,
   part 4 becomes P1. Lives with the claude hooks or `scripts/`.

2. P1 **Rule scope.** Done in dotfiles: path-scoped user rules moved into
   skills and skill references (`hooks/lib/skill-paths.zsh`,
   `ref-paths.zsh`): a pointer on Read, a deny on Edit/Write. Remaining
   item, no plan needed:
   in `rules/context7.md`, delete the
   paragraphs that repeat the MCP instructions; move `## Steps` to the
   `context7-mcp` skill or keep it as the whole rule.

3. P1 **Skill size.** Plan: (to write)
   Split `implement` so the forced load is the core only ("CLI &
   scripting" and Python into references or rules loaded by file type).
   Move reference sections out of provider-system ("Known ACP
   limitations"), claude ("CLAUDE.md Memory", "Built-in tool semantics";
   drop "External Integration Layers", which repeats acp), permissions,
   rendering, mlr. Smaller skills also shrink compaction re-injection.

4. P2 **Hook injection.** Plan: (to write)
   - `completion-review.sh`: fire only when the agent's own edits need a
     check; drop the "not by you" list or limit it to files the agent read;
     end without forcing a reply turn. Coordinate with the shell-edit
     tracking item in `hooks/TODO.md`.
   - Make task-independent injections conditional (bash-env on the first
     command it applies to, cwd-skill-guard).
   - `gitignore-guard.sh`: use the `remind_once` state file that
     `shell-guard.sh` uses; remove the ignored `once` key and the header
     comment that relies on it.
   - Keep one home for the symlink fact; drop the others.

5. P2 **Catalogue and connectors.** Plan: (to write)
   Make synced org skills, plugins (xyme-snow, slack, xyme-security) and
   claude.ai connectors (Miro, Notion, Linear, …) opt-in: off by default,
   enabled per project or per session where used (rare). Shorten own
   descriptions over ~400 B (provider-system, issues, subagents, debug,
   acp, install).

6. P2 **Model and effort routing.** Plan: (to write)
   - Claude side: `model:` and `effort:` frontmatter for mechanical agents
     in `agents/*.md` (learning-reviewer, docstring-reviewer, researcher);
     keep reviewers that judge correctness on the parent model. Built-in
     agents (Explore) have no frontmatter here: the plan decides between a
     own search agent and `CLAUDE_CODE_SUBAGENT_MODEL` (which applies to
     all subagents). `CLAUDE_CODE_EFFORT_LEVEL` must stay unset.
   - Cross-provider delegation in agentic.nvim, generalising the skeptic
     pattern: the main agent hands a bounded task to a `BackgroundSession`
     on a LiteLLM model (`glm-5.3`), and the result returns to the main
     agent. The plan decides:
     - Trigger: how the main agent asks for it (a tool the plugin exposes,
       a slash command, or a request file the plugin watches).
     - Channel: in-process (as skeptic) or markdown files in a cache dir
       (`~/.cache/nvim/agentic/…`), which also lets any provider read the
       result and keeps it out of the main context until asked for.
     - Thought level per task (set next to `_set_model`).
     - Which tasks qualify: read-only research, summaries, mechanical
       edits; nothing permission-sensitive without the normal permission
       flow.

7. P3 **Deterministic tools.** Plan: (to write)
   Measure the tool-output share of tokens with part 1 first (suspected
   large: `cargo` output in the Bevy project). If shell output is large: an in-house `updatedInput` truncation for test runners
   (the docs pattern), inside the existing guard chain, not rtk. Add
   ast-grep for structural edits. Move style checks from prose rules to a
   pre-commit formatter or reviewer agent (`hooks/TODO.md` § "Distribution
   of work").

## Expected outcome
- Per-session fixed context and per-turn re-injection drop, measured by
  part 1 against the 2026-11-13 baseline.
- Hooks inject only when the text applies to the current call.
- Mechanical subagent work runs on a cheaper Claude model or on LiteLLM
  models with no usage limit.

## Non-goals
- Routing the main Claude Code session through LiteLLM.
- Lossy third-party output compressors (rtk, headroom, caveman) without a
  measured need.
- Rewriting CLAUDE.md files by tool (caveman-style compression).

## Open questions
None.
