# Bug: zsh tree-sitter parser hang freezes nvim → SIGKILL (root cause confirmed)

A separate, still-valid O(n²) render perf bug lives in
`bug-autoscroll-conceal-perf.md`; it is unrelated to this crash.

## Root cause

`vim.treesitter.get_string_parser(src, "zsh"):parse()` **never returns** on
certain zsh input — a tight loop in the tree-sitter-zsh C parser
(`ts_parser__reduce → stack_node_release`). nvim's event loop never regains
control, so the editor freezes; it is eventually SIGKILLed (exit 137). A C-level
parse loop is uninterruptible — `pcall` and `timeout`'s SIGTERM are both ignored.

Minimal reproducer (hangs `parse()` forever):

```zsh
c=${x//[^)]}
```

A `${var//pattern}` substitution whose pattern is a bracket class `[^)]`
containing an unbalanced **close-paren**. `[^(]` (open-paren) parses fine — only
the close-paren loops.

### Why this matches every observation

- **Content-specific, not size-specific** — a grammar bug on a token sequence;
  buffer length is irrelevant (short/new sessions froze).
- **Fine in Claude TUI** — the TUI never tree-sitter-parses the content.
- **Hang → SIGKILL, no core/`.ips`** — an uninterruptible C loop, not a crash.
  SIGKILL is uncatchable, so core dumps and crash-signal handlers are useless;
  the only capture that works is a stack sample of the frozen process.
- **Both Bash and Edit tool calls froze** — two entry points reach the same
  parse (below).

### Confirmed via

Reproduced `cl "Review the uncommited work…"` in tmux; sampled the frozen nvim
(100% CPU, 3.8 GB, never self-terminated) — the stack was 100% in
`ts_parser_parse_string` (the parser itself). Bisected `lib/identifiers.zsh` to
line 63, then to the one-liner above.

### Deterministic headless repro

```
nvim --headless -u NONE -l - <<'LUA'
vim.treesitter.language.add("zsh", { path = vim.fn.expand("~/.local/share/nvim/site/parser/zsh.so") })
vim.treesitter.get_string_parser("c=${x//[^)]}", "zsh"):parse()   -- never returns
LUA
```
Wrap in `timeout -s KILL 8` — plain `timeout` (SIGTERM) will not stop it.

## Entry points (all synchronous, main thread, all reach the buggy parse)

- `lua/agentic/utils/shell_parse.lua:527` `parse_zsh` — permission walk /
  walk-into-scripts, which reads and parses a **sourced file's content**. Path
  for the Bash `source lib/identifiers.zsh` freeze.
- `lua/agentic/ui/diff_preview.lua:65-70` `build_highlight_map` — diff syntax
  highlight. Path for the Edit-to-`identifiers.zsh` freeze.
- `lua/agentic/utils/treesitter.lua:48` — context-aware highlight reconstruct.

Originally unguarded: the `pcall` in `parse_zsh` and the fail-open in
`build_highlight_map` wrapped `get_string_parser` (cheap), **not** `parse()`
(the loop), so they did nothing here. All three now bail before `parse()` via
the layer-1 guard (#4); the walk-into-scripts body parse also has the layer-2
subprocess oracle.

## Ruled out (do not re-chase)

The crash was first misattributed to the frontend's permission decision and then
to a render/conceal stall. Both are falsified:

- **The permission decision (`pm:decide`) is not the hang site — by reading, no
  reproduction needed.** The whole transitive path for a Bash/execute call —
  `permission_manager.lua:321` (`should_auto_reject` → `evaluate`, incl. the
  walk-into-scripts branch at `permission_rules.lua:1278-1307` that reads
  `identifiers.zsh`, re-parses with `parse_zsh`, recurses under `NESTED_MAX_DEPTH`;
  then `_bash_effects_clear`, cache, return) — contains **zero event-loop pump
  primitives** (`vim.wait`, `:wait()`, `vim.system`, `vim.fn.system`, `io.popen`,
  `getchar`, `vim.ui.*`, `confirm`, `input`, `:redraw`, `jobwait`). Swept across
  `permission_manager`, `permission_rules`, `permission_structured`, `shell_parse`.
  The one module with a pump (`git_files.lua`, `vim.system():wait()`) is reachable
  only via the trust-scope branch, gated on `FILE_SCOPED_KINDS = {edit, write,
  create, delete, move}`; Bash is `execute`, so it never runs. Without a pump, a
  synchronous `pm:decide` cannot host a re-entrant `session/update`, so the
  "deadlock triangle" theory is impossible. The missing `Bash → allow` log line
  (`permission_hook.lua:81`) is a *symptom* of the already-hung main thread, not
  its site — the permission RPC (`--remote-expr` into `$AGENTIC_SOCK`) simply
  could not be serviced.
- **The render/conceal stall was the wrong stack.** The leading theory was
  `nvim_win_text_height → decor_conceal_line → ts_query_cursor`; the confirmed
  frozen stack is in `ts_parser_parse_string` instead. (That render path is a
  *real* but separate perf bug — `bug-autoscroll-conceal-perf.md`.)
- **Isolated components on the exact command, all fast** (headless, under
  wallclock `timeout`): permission walk incl. walk-into-scripts sourcing
  `identifiers.zsh` (~76 ms); treesitter parse+highlight of the *command text*
  (raw zsh, ```` ```zsh ````/```` ```bash ```` fences, incremental); `shfmt -ln
  bash -i 2 -ci`; `split_at_operators`. These exercise the command, not the
  sourced file's `${var//[^)]}` line — which is why they passed while the live
  path froze.

## Fix workstreams

### 1. Upstream grammar (the real source fix)

Bug is in `georgeharker/tree-sitter-zsh` — an unbalanced `)` in a bracket class
inside `${var//pat}` loops the GLR reduce. **No existing issue** (checked
2026-07-08). Possibly-related open issues: #33 and #35 (scanner `size == length`
assertion failures — may be the same catastrophic-parse family; unconfirmed).
**Do not open an issue without express permission.**

### 2. Anti-pattern guard (must be regex, not tree-sitter) — DONE

Guard added to `bash-pitfall-guard.sh` (`paren_bracket_class`, `block_once`).
Regex-based because the tree-sitter-guard-engine
(`config/claude/hooks/feature-treesitter-guard-engine.md`, `shell_parse.lua`)
parses commands with the *same* `get_string_parser(…,"zsh")`, so a tree-sitter
guard would hang itself. Regex: `\$\{[^}]*/[^}]*\[[^]}\]*\)` — an unescaped `)`
inside a `[...]` class within a `${var/pat}`/`${var//pat}` substitution.

Danger boundary (verified headless): the hang fires for **any** bare `)` in a
bracket class inside a substitution (`[)]`, `[^)]`, `[a)b]`, single- or
double-slash). Escaped `\)`, open-paren `[^(]`, and paren-in-class *outside* a
substitution (globs, case patterns) are all safe — the guard rejects those.
Caveat: command guards only see *command text* — they do not cover the
file-content parse paths (diff highlight, walk-into-scripts), so this is a
re-introduction tripwire, not full coverage.

### 3. The trigger in the lib — DONE

`~/dotfiles/config/claude/hooks/lib/identifiers.zsh` `_trim_unbalanced_close`
counted parens with `o=${REPLY//[^(]}` / `c=${REPLY//[^)]}` (line 63 hung).
Rewritten to strip-and-measure, which uses no bracket class:

```zsh
open=$(( ${#REPLY} - ${#${REPLY//\(}} ))
close=$(( ${#REPLY} - ${#${REPLY//\)}} ))
```

Behaviour-preserving (diffed against the original across balanced/unbalanced/empty
cases). Verified the full file now parses to completion headless; the only
remaining match of the shape is the explanatory comment (lexed as a comment, so
harmless).

### 4. Isolate tree-sitter so a bad grammar can't take down the editor — DONE

A third-party grammar must degrade to "no highlighting / failed walk", never a
frozen editor. **Confirmed (headless):** no in-process mechanism can interrupt
this hang — not `pcall`, not `timeout`'s SIGTERM, and not neovim's async-parse
chunk timeout (`parse(range, on_parse)`, 3 ms chunks + `redrawtime` abort). The
async path still SIGKILLs on the reproducer: the C reduce loop never reaches a
cancellation checkpoint, so the first chunk enters C and never returns to the
coroutine. An OS-level kill is the *only* viable interrupt.

Shipped as two layers:

- **Layer 1 — cheap universal tripwire (`lua/agentic/utils/zsh_parse_guard.lua`).**
  `contains_hang_trigger(src)` is the #2 regex ported to a Lua pattern; it runs
  before every parse. Wired into `parse_zsh` (→ nil, fail-closed prompt) and
  both `build_highlight_map`s (`diff_preview.lua`, `utils/treesitter.lua` → nil,
  fail-open no highlight). This closes the **known** bug on all four entry
  points — including the diff-highlight path that caused the *Edit* freeze,
  which a walker-only fix would have missed — at ~µs cost, no subprocess.
- **Layer 2 — killable subprocess oracle (`ShellParse.parse_zsh_untrusted`,
  script `utils/zsh_parse_oracle.lua`).** Guards the two walk-into-scripts
  file-body parses (arbitrary on-disk content, the incident path, exposed to
  *unknown* future grammar bugs). Parses the body in `vim.system(nvim …
  -l oracle):wait(5000)`; a non-terminating grammar bug is SIGKILLed and treated
  as unparseable (nil → prompt). Only fires when a command sources/executes a
  script, so common Bash decisions pay nothing. **`SystemObj:wait` uses
  `vim.wait(…, fast_only=true)`** — it SIGKILLs on timeout ("cannot be caught")
  and does *not* dispatch deferred events (RPC/autocmds/`vim.schedule`), so it
  blocks the main thread without re-entering the permission decision. (This
  refines the earlier "no event-loop-pump on the Bash path" note under *Ruled
  out*: a `fast_only` wait does not reintroduce that re-entrancy.)

Not covered: unknown hangs on the *display* paths and on command/`-c` text
(layer 1 catches only the known shape there). Accepted — display fails
cosmetically, and command text is short and user-reviewed. A per-parse
subprocess on those hot paths was judged disproportionate.

### 5. Async parsing — DOES NOT fix this bug class (tested)

The async parse API (`parser:parse(true, on_parse_cb)`) was tested against the
reproducer headless: still exit 137 (SIGKILL). It splits work into 3 ms chunks
and aborts at `redrawtime`, but the abort is only checked *between* chunks — a C
reduce loop that never yields never gets checked. Async parsing helps only
*slow-but-terminating* parses (keeps the UI responsive during a big-but-finite
parse); it cannot rescue an uninterruptible loop. Not a substitute for #4.

## Artifacts

- Crash session (Edit freeze): `~/.claude/projects/-Users-cmadsen-dotfiles-config-claude-hooks/93c34565-320a-428c-90e5-1ecf3178e68d.jsonl` — last tool_use is the Edit to `identifiers.zsh`; the trailing "tool rejected / interrupted" is a crash artifact (ACP connection dropped), not a real rejection.
- Earlier Bash-`source` freezes: `a747a8b8-…`, `96187ba5-…` in the same project dir.
- Capture recipe for a live hang (sample the process owning `$AGENTIC_SOCK`
  before it dies): `sample <pid> 3` + `lldb -b -o "process attach --pid <pid>"
  -o "bt all" -o detach -o quit`. `sample` does not stop the target.
