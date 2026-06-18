# Tree-sitter guard engine — migrating the Claude/opencode hook command guards

Status: A1 done — `lua/agentic/utils/shell_parse.lua` is the single home for the
structural primitives + `extract_commands`; `permission_rules.lua` requires it
(its walks rebuilt on the shared primitives, −534 lines, all tests green).
A2 not started. Spans two repos:
`~/dotfiles/config/claude/hooks/` depends on
`~/dotfiles/config/nvim/modules/agentic.nvim/` (both in dotfiles; agentic.nvim
is a submodule).

## Motivation

1. **Regex is fragile.** The current command guards use ERE (`shell-guard.sh`,
   `bash-pitfall-guard.sh`, …) with a hand-rolled `strip_nonexec_literals` to
   avoid false positives. The headline bug: the `rm -f` guard fires on
   `git commit -m "...rm -f..."`. Tree-sitter eliminates this structurally.
2. **Two implementations.** Guards are zsh for Claude, JS for opencode. A shared
   matcher gives one source of truth across providers.
3. **Conciseness.** Beyond robustness — a parsed `{name, flags, args}` lets rules
   be declarative match-specs instead of boundary-regex incantations.

## Scope & framing

Three pieces, three homes. Do not conflate them — in particular, the guard
engine is **not** an agentic.nvim feature:

- **A1. Matcher** — a plugin library. The extraction core refactored out of
  `permission_rules.lua` so it yields normalized `{name, flags, args}` records.
  This is the *only* part that lives in agentic.nvim. The plugin stays unaware it
  is being recycled from `~/.config/claude` and `~/.config/opencode`; from its own
  side this is a pure modularity refactor that also cleans up the permission code.
- **A2. Guard engine** — lives in `config/claude/hooks/` (+ opencode config), not
  the plugin. Rule table, `guard.lua` entry, the two adapters, parity tests,
  regex backstop. Consumes A1 across the submodule boundary. The dependency arrow
  is one-way: hooks → plugin.
- **B. Session-state authority** (tracking UI: files read/touched) — observe-only,
  consumes the ACP `tool_call` stream. Separate project; intersects A2 only at
  Phase 2 (the marker store).

v1 of A covers **command (Bash) guards only**. File-content guards
(`style-guard`, `python-import-guard`, `home-path-guard`) stay as-is — they parse
the *edited file's* language, a different problem (prose guards already use
tree-sitter via `prose-extract.lua`). The rule-table + adapter pattern
generalizes to content guards later via a per-language extractor; don't build
that until the command engine is proven.

## Why not the obvious approaches (verified against source, not assumed)

- **The ACP client cannot be a universal blocker.** `session/request_permission`
  only fires for tools the SDK escalates to `ask` (verified in bridge
  `acp-agent.js:1492` `canUseTool` → `:1534` `requestPermission`, claude-agent-acp
  0.44.0). Read-only and allow-listed tools are approved *inside* the SDK and
  never reach the client. Blocking lives in each provider's **native** hook
  system: Claude SDK `PreToolUse` hooks (fire on every tool, run by the spawned
  `claude` CLI), opencode `tool.execute.before` (throw → tool failure). opencode's
  `permission.ask` hook is declared-but-never-triggered.
  - Refinement: the plugin *could* inject `PreToolUse` hooks via
    `_meta.claudeCode.options.hooks` (bridge spreads it at `:1992`) — and those
    hooks *can* be in-process Lua (the injected command is a thin shim that
    round-trips to `$NVIM` via `--remote-expr`). Rejected anyway: injected hooks
    only exist while the plugin is the ACP host, so they vanish the moment you
    drop back to the bare Claude TUI — exactly the fallback case the guards must
    survive. The host-independent settings.json hook is the only delivery that
    works with or without the plugin running.
- **Fake-hook-via-cancel is strictly worse.** `tool_call` is a fire-and-forget
  `session/update` notification (no barrier — `await this.client.sessionUpdate`
  only awaits the local pipe write). By the time the client reacts the command
  may already have run; `session/cancel` tears down the whole turn. Dropped.
- **JS reimplementation is indefensible.** `lua/agentic/utils/permission_rules.lua`
  (1961 lines) already does the hard part — recursive zsh parse-tree walk
  (`walk_command`/`walk_redirected`/`walk_assignment`/`walk_for`/`walk_while`/
  `walk_do_group`) + getopt arity (`WrapperSpec`: `value_opts`/`flag_opts`/
  `attached`/`positionals`), exec-wrapper recursion (`timeout`/`time`/`stdbuf`),
  substitution/redirect handling, fail-closed on `ERROR` nodes — using the **zsh
  grammar** (`get_string_parser(src, "zsh")`, `:894`). Porting to JS = two
  safety-critical copies that must never diverge.

## Architecture

- **A1 — matcher** = pure Lua, `string → {id, action, text}[]`. No state, no I/O,
  no `Config`. Built by refactoring the extraction core out of
  `permission_rules.lua`'s walkers so they yield normalized `{name, flags, args}`
  command records (currently they check `ctx.allow` inline; that matching stays on
  the plugin's permission side, extraction becomes a standalone pure function).
  - From the plugin's perspective this is **just a modularity refactor** — it is
    unaware the records are recycled by external hooks. The win is real on its own
    merits (separating extraction from `ctx.allow` matching cleans up the
    permission code), so A1 is justified even if A2 never ships.
  - The agnosticism is the same property that makes it headless-loadable: the
    extraction path must pull in nothing from `Config` or the live runtime at
    require time, so it loads under `nvim -u NONE` (Mode 2).
  - **One-way coupling, one-way breakage detection.** The plugin carries no test
    that fails if it breaks the hooks (`permission_rules.test.lua` asserts only
    *its* verdicts, not the record shape). The integration oracle is the
    hooks-side parity corpus, which must run in the **dotfiles** validation, not
    the plugin's.
- **A1 API contract** (pinned — `rm -f` exercises all of it; settle before the
  refactor, the rest of the vocabulary is decided by its first real rule):
  - **New module `lua/agentic/utils/shell_parse.lua`, zero plugin requires** (only
    `vim.treesitter`). `permission_rules.lua` requires it and keeps the
    `Config`-driven matching on its side. Not an export from `permission_rules.lua`
    — that file requires `agentic.config`/`agentic.utils.logger` at the top, so
    requiring it under `-u NONE` drags the runtime in and breaks Mode 2.
  - **Record = `{ name, flags, args }`, post-normalization, post-unwrap:**
    - `flags` — short clusters split during extraction (`-rf` → `{"-r","-f"}`), so
      the evaluator stays dumb. Long flags kept whole (`--force`).
    - `name` is the *unwrapped inner* command: `timeout 5 rm -f x` → `name="rm"`
      (walkers already skip `timeout`/`time`/`stdbuf` operands). Records are
      flattened across substitutions: `git commit -m "$(rm -rf /)"` → `[git, rm]`.
    - `args` — positionals (subcommand resolution is deferred; see vocabulary).
  - **Record-shape question — resolved: shared primitives, two walks.** The flat
    `{name, flags, args}` list serves the guard ("does any extracted command match
    a block rule, fail-closed on opacity"); it is *not* a drop-in for the
    permission verdict, which needs structural facts the flat list discards —
    dynamic-token wildcarding (`find . $(echo -exec rm)` must bail because the
    substitution output, spliced as a *dynamic* arg, wildcards find's `-exec` deny;
    see `perm-extend-auto-approve.md` #4), redirect safety, env-prefix hijack,
    position-sensitivity. A single rich record for both would just re-encode the
    parse tree. So the de-dup is at the *primitive* level, not the walk: `walk`
    (verdict) and `collect`/`extract_commands` (list) are distinct traversals that
    share one copy of every primitive (`literal_token`, `command_name_text`,
    `inner_source`, the node-type sets, …). No `args_dynamic` leaks into the guard
    record.
  - **Fail-closed via `nil`, not `{}`.** Parse error / absent parser / `ERROR`
    node → `extract_commands` returns `nil`; `guard.lua` treats `nil` as "can't
    prove safe" and fires any `block` rule. `{}` means "parsed, no command"
    (bare string) → nothing fires. Conflating the two is the silent-miss bug for
    `rm -f`.
- **Match vocabulary** — exactly four primitives, no more:
  | primitive | matches |
  |---|---|
  | `command` | the `command_name` (string or list-of-alternatives) |
  | `flag` | any of these flags present (handles bundled `-rf`) |
  | `subcommand` | first **true** positional — resolved via getopt arity, NOT naive first-arg (a flag may consume the next token, the `permissions.json` problem) |
  | `arg~` | regex against any argument (escape hatch for the long tail) |
- **Actions:** `block` / `block_once` / `remind` / `remind_once`.
- **A2 — rules** = one Lua file at a fixed path **in `config/claude/hooks/`**, not
  the plugin tree. Loaded only by `guard.lua` (the live plugin never loads it —
  there is no in-plugin guard consumer). The plain
  `{ command, flag, …, action, text, id? }` table. `id` defaults to a slug of
  command+action. The opencode JS adapter never reads it — it only ever gets
  verdicts back. "Single source of truth" is satisfied by there being *one file*;
  its directory is irrelevant — opencode passes the path the same way it passes
  the plugin rtp path for the matcher. No JSON.
- **A2 — adapters** (thin): the claude zsh hook + opencode js plugin call the
  matcher via nvim (`$NVIM` remote-expr when live, headless spawn otherwise) and
  deliver through their native channels (deny+message / `throw` /
  `additionalContext` / output-append). The plugin's own permission gate is **not**
  a delivery path — it only sees `ask`-escalated tools, a strict subset the
  host-independent hook already covers.

Example rule:

```lua
{ command = "rm", flag = { "-f", "--force" }, action = "block",
  text = "rm -f/--force is never allowed. Use plain rm instead." }
```

## Run modes

Both modes run the matcher through nvim from the host-independent hook. There is
no "evaluate at the plugin's permission gate" mode — the gate only sees
`ask`-escalated tools (a subset the hook already covers) and disappears in the
bare TUI.

- **Mode 2 (Phase 1) — headless:** `nvim --headless -u NONE --cmd 'set rtp+=<plugin>'
  -l guard.lua`. The matcher lives in the plugin; the live runtime is not started —
  only the pure module + zsh parser are loaded. Invoke directly per command; **no
  pre-filter cache** (dropped as premature optimization).
- **Mode 3 (Phase 2) — live instance:** child processes inherit `$NVIM`; adapter
  does `nvim --server $NVIM --remote-expr 'luaeval(...)'` into the already-loaded
  instance. Few-ms RPC, no cold start. Add only if Mode 2 latency bites. (This is
  the in-process path when you *are* in the plugin — it supersedes the deleted
  gate idea: same speed, full coverage, no dependence on the SDK escalating.)

## Once-per-session

- The pure matcher never holds it.
- **Phase 1:** reuse the existing marker stores as-is — `/tmp/claude-hooks/<session>/<id>`
  (our hand-rolled code in `core.zsh`) + opencode's module `Map<sessionId, Set>`.
- **Phase 2:** once project B exists, once-ness moves into the plugin
  **session-state authority** (files read + files touched + reminders fired = one
  store), consulted via the live instance (Mode 3). Retires the two hand-rolled
  stores for the plugin-mediated path. Requires the live instance — a fresh
  headless spawn has no shared memory — so a degraded fire-every-time (or minimal
  marker) fallback covers non-plugin usage (Claude TUI).

## Coupling accepted

`config/claude/hooks/` gains a hard dependency on the agentic.nvim submodule path.
On a machine without it (or submodule not checked out) the headless route breaks —
the hook must **fall back gracefully** (keep the regex `rm -f` backstop, skip the
rest) rather than error.

## Safety & migration

- **Fail closed:** parse error / `ERROR` node → "can't prove safe" (as
  `parse_zsh` already does). For `rm -f`, a silent miss is unacceptable.
- **Permanent regex `rm -f` backstop** stays in the hook — defense-in-depth +
  plugin-absent fallback.
- **Incremental, `rm -f` first** (headline bug, highest-stakes block, smallest
  rule). Port it, delete its regex from `shell-guard.sh`, ship. Then the next.
  Never big-bang. Guards to migrate: `rm -f`, `conda activate`/`install`,
  `curl|sh`, `zcat`, `git checkout --`, plus the `python-exec`/`uv-run` reminders.
- **`tests/` corpus is the parity oracle.** For each guard: assert the matcher
  gives the same verdict as today, then add the cases the regex gets *wrong*
  (`git commit -m "...rm -f..."`, `echo 'rm -f'`) as new passing tests. No live
  shadow-running — validate offline, cut each guard over cleanly.

## Validated (zsh grammar, `get_string_parser`)

- `git commit -m "remove the rm -f guard"` → commands extracted: **`[git]`**
  (the `rm -f` text is `(string (string_content))`, not a command). Headline bug
  structurally gone.
- `echo 'rm -f x' ; ls` → `[echo, ls]` (`rm -f x` is `(raw_string)`).
- `git commit -m "$(printf 'rm -rf /')"` → `[git, printf]` (live substitution's
  command seen; `rm` inside the single-quoted arg not). Correct live-vs-inert
  discrimination — what `strip_nonexec_literals` hand-approximates.
- `bash.so` is NOT installed and the execute tool runs **zsh** on this machine for
  **both** providers (Claude via `$SHELL`; opencode `shell.ts:195` sources
  `.zshrc` and runs `zsh -l -c`). So the zsh grammar is the correct and available
  choice. (If a JS host were ever needed: `tree-sitter-bash` ships a prebuilt
  `.wasm`; `tree-sitter-zsh@0.63.1` ships only `.node` prebuilds → would need a
  docker `tree-sitter build --wasm`. Moot under the Lua-engine decision.)

## Open implementation tasks

**A1 (plugin — modularity refactor):**

1. **Done.** `lua/agentic/utils/shell_parse.lua` (zero plugin requires) exposes
   `extract_commands(src)` per the pinned A1 API contract — flag-split records,
   exec-wrapper + inline `-c` unwrap, substitution flattening, fail-closed `nil`.
   Covered by `shell_parse.test.lua` (14 cases incl. the headline `git commit -m
   "...rm -f..."` false positive). Verified to load under `nvim -u NONE`.
2. **Done.** `permission_rules.lua` requires `shell_parse` and aliases the
   primitives locally; its `walk`/`tally_walk` are unchanged in logic but now
   call the shared copies (−534 lines, every primitive definition moved out).
   `M.strip_command_path` stays as a one-line re-export (public API + its test
   preserved). `permission_rules.test.lua` (incl. the #3 cases) and
   `shell_parse.test.lua` both pass — the refactor is behaviour-preserving. Zero
   duplicated primitives remain.

**A2 (`config/claude/hooks/` — consumes A1):**

> **Handoff — next agent starts here.** A1 is shipped and is the only dependency.
> The API consumed across the submodule boundary is:
> `require("agentic.utils.shell_parse").extract_commands(src)` → `agentic.ShellCommand[]`
> (`{ name, flags, args }`, flags short-split) or `nil` (fail-closed: parse error,
> dynamic name, code-taking builtin). It loads with only the plugin on the rtp
> (`nvim --headless -u NONE --cmd 'set rtp+=<plugin>' -l guard.lua`, Mode 2 — see
> Run modes). All of A2 is **hooks-repo work** (`config/claude/hooks/` + opencode
> config) — no further plugin changes; the plugin stays unaware of the guard.
> Match vocabulary, actions, rule shape, and the run modes are specified above;
> migrate `rm -f` first (§ Safety & migration). The parity corpus runs in the
> **dotfiles** validation, not the plugin's suite.

3. Build the 4-primitive rule evaluator over A1's records.
4. `guard.lua` entry: load rule file, match, print verdict line(s).
5. Rule file at a fixed path in `config/claude/hooks/` + initial `rm -f` rule.
6. Claude zsh adapter: replace `has_rm_force` call with matcher invocation; keep
   regex backstop + graceful fallback (submodule-absent path).
7. opencode JS adapter: invoke matcher, map verdicts to throw/append.
8. Parity tests from the hooks-side corpus + new false-positive cases. These run
   in the **dotfiles** validation (the one-way breakage detector for A1 changes),
   not the plugin's suite.
