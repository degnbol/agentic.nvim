# Handover: spontaneous nvim death during specific hook-editing sessions

## Objective

Find why nvim dies ("crashes") during certain agentic.nvim sessions. **Root cause
is NOT yet confirmed**, but now narrowed to the **agentic.nvim frontend** — the
exact crash commands run fine in plain Claude TUI (see "Cross-check"). This
document is the evidence + what's ruled out + the one capture step that will close
it. A separate perf bug found along the way is in
`notes/bug-hang.md` — it is **probably not** this crash (see there).

## What "crash" means here (important)

It is a **hang, then SIGKILL** — not a segfault/abort.

- Reproduced once under observation: the window **froze**, then the process ended
  with **exit 137 = 128 + SIGKILL(9)**.
- **No macOS `.ips` crash report** and **no core** (a real crash would leave an
  `.ips`; `ulimit -c` was 0). SIGKILL is uncatchable → debuggers, core dumps, and
  crash-signal handlers are all **useless** for this. Do not go down that road.
- Consequence: the only useful capture is a **stack sample of the frozen process
  while it is still hung** (before the kill). See "How to capture" below.

## The two incidents

Both were **short, NEW sessions**, in `~/dotfiles/config/claude/hooks`, doing the
**same task**: tightening the SMILES/identifier guard's false positives. Both died
right after the agent issued an execute (Bash) tool_call for a command that
`source`s `lib/identifiers.zsh` and runs `smiles_feature_count` over a list of
literal strings in a `for` loop.

Surviving Claude transcripts (agentic never persisted its own session cache — it
died before `ChatHistory:save`, so `:AgenticResume` cannot see them). Under
`~/.claude/projects/-Users-cmadsen-dotfiles-config-claude-hooks/`:

- `a747a8b8-7ed0-4763-adab-93f2bab60b44.jsonl`
- `96187ba5-fc52-48ad-9096-797f16e6f386.jsonl`

(Original crash times: Jul 6, ~14:57 and ~15:08 local. `a747a8b8`'s mtime is now
later because it was resumed during investigation.)

### The exact commands they died on

Recovered from the transcripts (the trailing `smiles_feature_count` loops — the
last Bash `tool_call` before each death). Same shape in both: `source
lib/identifiers.zsh`, then loop `smiles_feature_count` over a list of literal
strings, gating on `feat >= 2 && [[ $c =~ [BCNOPSFIbcnops] ]]`. `a747a8b8`
(final of three such loops):

```zsh
cd ~/dotfiles/config/claude/hooks
source lib/identifiers.zsh 2>/dev/null
for c in <code-shaped probe strings> 'CC(=O)Oc1ccccc1C(=O)O' <…>; do
  smiles_feature_count "$c"; feat=$REPLY
  gate="reject"
  (( feat >= 2 )) && [[ "$c" =~ [BCNOPSFIbcnops] ]] && gate="LOOKUP→PubChem"
  printf '%-14s feat=%d  %s\n' "$gate" "$feat" "$c"
done
```

`96187ba5` grep-extracted 10+-char candidate runs from a probe file and fed them
through a `while read` loop with the same `source` + `smiles_feature_count` gate.

Full literal token lists are in the two transcripts. They are deliberately
code-shaped false-positive probes — function calls with keyword arguments, array
subscripts, type-hint annotations — plus one real SMILES (aspirin,
`CC(=O)Oc1ccccc1C(=O)O`); exactly the strings the guard-tightening task existed to
test. Fittingly, the identifier guard flags several of them as "hallucinated
SMILES" when they land in committed text (it blocked them while this very note was
being written) — the exact false-positive class under investigation.

## The key discriminator (weight this heavily)

Per the user, and this is the strongest constraint:

- **Crashes happened only in short, new sessions running this specific task.**
- **All other sessions are fine, regardless of length.**

So the cause is tied to **what those sessions did**, NOT to session age, chat
size, or buffer growth. Any hypothesis that scales with size (including the
`bug-hang.md` O(n²) stall) is contradicted by this and should be treated as a
different problem.

What is unusual about the task, as leads:
- Fresh session, cwd `~/dotfiles/config/claude/hooks`.
- Editing identifier/SMILES guard files.
- Bash commands containing chemistry/SMILES-like tokens (e.g.
  `CC(=O)Oc1ccccc1C(=O)O`), a regex char-class `[[ "$c" =~ [BCNOPSFIbcnops] ]]`,
  and `source lib/identifiers.zsh` (exercises the permission "walk into script
  files" feature).

## Hard evidence

- **Debug log** (`~/.cache/nvim/agentic_debug.log`, shared by all nvim
  instances): the last logged activity before death was the execute
  `tool_call` / `tool_call_update` for the offending command. There is **no
  `permission_hook: Bash → allow` line** for it. So either `pm:decide` was
  entered and never returned, **or** the main thread was already blocked before
  the hook fired. (See `lua/agentic/permission_hook.lua:81` — that log line is
  emitted immediately after `pm:decide` returns.)
- The permission verdict runs **synchronously on the nvim main thread**:
  `hooks/permission_hook.sh` calls `nvim --server $AGENTIC_SOCK --remote-expr`,
  which evaluates `M.evaluate → pm:decide` in the live UI nvim. A hang inside
  that path (or in whatever the main thread was doing when the RPC arrived)
  freezes the whole editor.

## One live reproduction (partial)

During investigation, resuming `a747a8b8` via `load_acp_session` (see repro
recipe) **rendered the transcript fine (no crash)**. Then asking it to *continue
its work* made it run a similar `smiles_feature_count` command, and the window
**froze and was SIGKILL'd (137)**. So:

- **Render-on-load is not the trigger** (caveat: the ACP client filters some
  updates during `session/load` replay, so replay is not a byte-identical render
  to live execution).
- **The live execute path is implicated**, but we **did not capture the stuck
  stack** at that moment (the capture tool in place was a signal-catcher, useless
  vs SIGKILL). This is the missing piece.

## Cross-check: plain Claude TUI runs the same commands fine (2026-07-08)

Reran all three `smiles_feature_count` loops (both `for` loops from `a747a8b8`,
the `while read` loop from `96187ba5`) **verbatim** in an ordinary Claude Code TUI
session, same cwd. Every one completed instantly — **no freeze, no SIGKILL**.

So the Bash payload is harmless on its own: the SMILES-like tokens, the
`[[ $c =~ [BCNOPSFIbcnops] ]]` char-class, and `source lib/identifiers.zsh` do
nothing pathological when a plain agent runs them. This **confirms the "live-only"
conclusion above and narrows it to the agentic.nvim frontend, not the command.**
Claude TUI runs Bash directly in the agent's own process — no editor render loop,
no permission RPC into a live UI nvim. agentic.nvim routes each permission
decision synchronously via `nvim --server --remote-expr` into the main thread's
`pm:decide` while the ACP event loop concurrently delivers `session/update` render
events. Only that second model crashes.

### Leading explanation (unconfirmed)

The frontend's concurrency model is the fault, not command semantics. The
synchronous `--remote-expr` permission RPC blocks the nvim main thread inside
`pm:decide`; if anything on that path pumps the event loop (see hypothesis 1), a
re-entrant `session/update` for the just-issued `tool_call` fires while the main
thread is mid-decision → deadlock/livelock → the window freezes and is SIGKILL'd.
Why *these* commands and not others: they are the first tool calls whose
permission walk descends into `source lib/identifiers.zsh` (the walk-into-scripts
feature), a heavier/slower decision that widens the window during which the main
thread is busy in the RPC while render updates queue behind it. This matches the
two hard facts — "no `→ allow` logged" (decision entered, never returned) and
"task-specific, not size-specific."

### Fix ideas (unconfirmed)

- **Don't block the main thread on the permission decision.** Evaluate
  `pm:decide` without a synchronous `--remote-expr` round-trip into the live UI —
  e.g. return a deferred/async verdict so the ACP render loop is never frozen
  waiting on it.
- **Guard against re-entrancy while a decision is in flight.** Queue/suppress
  incoming `session/update` processing until `pm:decide` returns, the same
  discipline already applied at `tool_call_renderer.lua:315-317`.

Either removes the deadlock triangle regardless of which command triggers it.

## Ruled out (isolated headless nvim, on the exact/near-exact command; none hung)

Each run under a wallclock `timeout`; all completed fast:

- **Permission walk**, including walk-into-scripts actually sourcing
  `identifiers.zsh`: `PermissionRules.should_auto_reject` + `evaluate` ≈ 76 ms.
- **`pm:decide`'s remaining steps** (`_bash_effects_clear`) — cannot loop.
- **Treesitter** parse + highlights over the command: raw `zsh`, markdown
  ```` ```zsh ````/```` ```bash ```` fences, and incremental line-by-line. Fast.
- **`shfmt`** (`-ln bash -i 2 -ci`) on the command. Fast.
- **`split_at_operators`** — returns early for multiline input; every branch
  advances the cursor, so no infinite loop.

Implication: the fault is **not** in any of these as a pure synchronous unit on
this input. It is live-only — i.e. it needs the real ACP event loop + the
synchronous `--remote-expr` permission RPC interacting with concurrent
render/IO. That interaction is what could not be reproduced headless.

## Open hypotheses (where to look next)

1. **Re-entrancy / deadlock in the live async path.** The codebase already has a
   documented re-entrancy hazard: `lua/agentic/ui/tool_call_renderer.lua:315-317`
   deliberately uses blocking `vim.fn.system` (not `vim.system():wait()`) because
   pumping the event loop mid-render lets **re-entrant ACP callbacks fire and
   corrupt buffer state**. Look for other spots where the main thread pumps the
   loop (`vim.wait`, `vim.system():wait`, `getchar`, `vim.ui`/`confirm`,
   `:redraw`) during render or during the `--remote-expr` `pm:decide`, allowing
   a re-entrant `session/update` to recurse → livelock/deadlock. This fits
   "no `→ allow` logged" and "task-specific, not size-specific."
2. **Recent permission-walk features** shipped just before the crashes (candidates
   for a bad interaction with `source lib/identifiers.zsh` + these tokens):
   - `4511870` (Jul 6 13:21) recurse xargs into inner command
   - `d51d6bb` (Jul 6 14:00) gunzip -c
   These are the last feature commits before the ~14:57/15:08 deaths. The walk
   tested fast in isolation, but test them *in the live path*, not just headless.
3. **New-session early lifecycle** × these commands — something that only runs in
   a fresh session (first tool call, first permission decision, first render of a
   specific block kind), not in an already-warmed one.

## How to reproduce

1. Launch nvim so a watcher can attach (see capture recipe). Open agentic.
2. Load a crashed transcript directly (bypasses the missing agentic cache):
   ```
   :lua require("agentic").load_acp_session("a747a8b8-7ed0-4763-adab-93f2bab60b44", vim.fn.expand("~/dotfiles/config/claude/hooks"))
   ```
   (The "No session found" style error from `:AgenticResume` is expected — that
   command needs the agentic cache; `load_acp_session` uses ACP `session/load`
   against the surviving Claude transcript.)
3. It should load without crashing. Then prompt it to **re-run the exact
   `smiles_feature_count … source lib/identifiers.zsh` loop** so a live execute
   tool_call fires. That is what froze it before.

## How to CAPTURE the cause (the decisive step)

It's a hang → SIGKILL, so **sample the frozen process before it dies**. `sample`
does not stop the target; lldb-attach stops it briefly to dump all thread stacks.

Target = the nvim that owns `$AGENTIC_SOCK` (the UI/agent host; in the observed
run it was a child nvim, not the terminal one — resolve by socket, not by
guessing). Find it: `lsof` the socket path, or match `nvim.<pid>` in
`$AGENTIC_SOCK`.

Auto-capture on freeze (leftover helper `/tmp/nvim-hangwatch` does exactly this;
adapt the socket/pid): probe the server every ~2 s with
`timeout 5 nvim --server "$AGENTIC_SOCK" --remote-expr '1'`; when it stops
answering, the main loop is blocked → immediately:

```
sample <pid> 3 -f /tmp/nvim-hang-sample.txt
lldb -b -o "process attach --pid <pid>" -o "bt all" -o "detach" -o "quit" > /tmp/nvim-hang-bt.txt 2>&1
```

The main-thread backtrace at that instant is the answer: `waitpid` = blocked on a
subprocess; `poll`/`read` on the ACP pipe = the deadlock triangle; a Lua/C loop =
a runaway in that function. (For reference, the *perf* stall in `bug-hang.md`
shows as `nvim_win_text_height → decor_conceal_line → ts_query_cursor` — if the
crash-time stack shows that instead, the two are the same after all; current
evidence says they are not.)

## Artifacts / paths

- Transcripts: the two `.jsonl` files above.
- Debug log: `~/.cache/nvim/agentic_debug.log` (grep the offending command; note
  the missing `permission_hook: … → allow` line).
- Investigation samples (healthy session under load, for contrast):
  `/tmp/nvim-sample-1027.txt` (agent host), `/tmp/nvim-sample-1025.txt`
  (terminal nvim), `/tmp/nvim-sample-load.txt` (under render load).
- Capture helper: `/tmp/nvim-hangwatch`, launcher `/tmp/nvim-traced`
  (launches nvim on `--listen /tmp/nvim-trace.sock`, records pid).
- Related but separate perf bug: `notes/bug-hang.md`.

## Do-not-repeat (already tried, dead ends)

- Core dumps / `.ips` / crash-signal catchers — SIGKILL can't be trapped; nothing
  is produced.
- `git bisect` / iterative logging — the user explicitly rejected these as too
  slow; prefer capture-the-hang + reasoning.
- Re-testing the isolated permission walk / treesitter / shfmt / split — already
  falsified on the exact command.
