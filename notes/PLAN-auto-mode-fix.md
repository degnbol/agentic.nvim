# PLAN: honour explicit `ask` gates under auto mode

Status: **design; not started.** Extends `PLAN-auto-mode-integration.md` (the
hook transport, session routing, and `decide` refactor described there are
prerequisites and assumed done).

## Problem

Under auto mode a command that matches an explicit `ask` gate in
`permissions.json` (e.g. `git commit`, in `permissions.json`'s `git` → `ask`
array) is auto-allowed by the SDK classifier without prompting. The deterministic
ladder is supposed to gate it first.

Root cause: `PermissionManager:decide` (`lua/agentic/ui/permission_manager.lua:321`)
returns `"allow" | "deny" | nil`, and folds two different outcomes into `nil`:

- **explicit `ask`** — a rule matched; the user asked to be prompted for this.
- **defer** — no rule matched; the ladder cannot prove anything, legitimately
  the classifier's residue.

`should_auto_reject` (`lua/agentic/utils/permission_rules.lua:2537`) is
concrete-**deny**-only, so an `ask` match is not a reject; `evaluate`
(`lua/agentic/utils/permission_rules.lua:2584`) returns `ok = false` for *both*
"an `ask` gate blocked approval" and "no allow rule matched". So `decide` returns
`nil` in both cases. `permission_hook.evaluate` maps `nil` → `""`,
`permission_hook.sh` emits no `permissionDecision`, and the call falls through to
the classifier (`internals.md` § "PreToolUse decision vs the permission
resolver": *no decision → resolver handles it*; in auto mode the resolver **is**
the classifier).

In the interactive (`canUseTool`) path the conflation is harmless — both `nil`
outcomes fall through to the same prompt. Only the auto/hook path loses the
distinction.

## Rejected options (do not relitigate)

- **Map `ask` → hook `deny`.** `deny` is a hard reject: `tool.call()` never
  runs, an `is_error` `tool_result` goes to the model (`internals.md` step 5).
  The agent could then *never* commit in auto mode — that is refusal, not a
  prompt. `ask` means "route the decision to the user", which `deny` cannot
  express.
- **A fifth `permissionDecision`.** There is none.
  `HookPermissionDecision = 'allow' | 'deny' | 'ask' | 'defer'` (`sdk.d.ts`).
  In auto mode: `allow` short-circuits only when unobstructed, `deny` hard-rejects,
  `ask` defers to the classifier (does *not* prompt), `defer` is print-mode-only
  and ignored over ACP with a warning. None forces the interactive prompt.
  `PreToolUseHookSpecificOutput` carries only
  `permissionDecision`/`permissionDecisionReason`/`updatedInput`/`additionalContext`
  — no mode lever and no `updatedPermissions` (`sdk.d.ts:2180`).
- **Temporarily flip the session out of auto mode from the hook.** Broken by
  ordering: mode lives in the SDK process; the only lever is an async
  `session/set_mode` ACP request, processed on the SDK message loop — which is
  blocked running the current tool call while the hook runs. The flip cannot
  land before the resolver reads mode at step 5 of *this* call, so this call
  still hits the classifier and the flip leaks to a later call. Also
  session-global (thrashes concurrent calls + the `agentic_headers` pipeline)
  and needs restore bookkeeping with no completion callback.
- **Block inside nvim (`vim.wait`) for the answer.** `vim.wait` pumps the libuv
  loop (timers, IO, `vim.schedule`) but does **not** dispatch mapped keys — the
  permission answer arrives via buffer-local normal-mode keymaps
  (`1`/`2`/… → `_complete_request`), which only fire from nvim's main input loop.
  A blocking `vim.wait` prevents nvim from reaching that loop, so the user's
  keypress is never processed and every prompt would time out. The fix below
  therefore does the waiting in the **shell hook process**, keeping every RPC
  into nvim short and non-blocking so the main loop stays free to dispatch the
  answer.

## Fix: distinguish `ask`, and drive the prompt by polling from the hook shell

The only place a prompt can originate in auto mode is the hook. But the hook
must **not** block inside nvim (see the last rejected option). Instead: on an
explicit `ask`, the hook RPC *enqueues* the plugin's normal permission float and
returns immediately; the hook **shell process** then polls nvim until the user
answers, and emits the answer as the hook's `allow`/`deny` verdict. nvim never
blocks, so the float's existing keymaps dispatch the answer normally, and the
prompt UX is identical to the interactive `canUseTool` path.

### 1. Surface `ask` as a distinct ladder verdict

- New existential pass in `lua/agentic/utils/permission_rules.lua`, mirroring
  `should_auto_reject`: `should_prompt(command) → boolean`, true iff a concrete
  executed leaf matches an `ask` gate (structured `ask` array or glob `ask`
  pattern). **Concrete-only** and **fail-closed-to-false** (no parser / parse
  error / over-long → `false`), identical discipline to `should_auto_reject`.
  Dynamic-token evasion of an `ask` gate (`git $x`) therefore falls through to
  the classifier — the same accepted residual the concrete-only deny pass
  already has in auto mode, and acceptable because the classifier is the
  designated residue handler.
  - The structured layer already reports `ask` (`permission_structured` classify
    path); the pass needs a concrete-only `ask_leaf` mirroring the existing
    `deny_leaf`, plus the glob `ask` patterns from `get_ask_patterns`.
  - Alternative considered: extend `evaluate`'s walk to also report an
    `ask`-matched flag. Rejected to keep the hot approve path unchanged; the
    separate pass only runs on the cold not-approved branch.
- `decide` gains an `ask` branch **immediately before the final `return nil`**
  (so every allow opportunity — read-only, `evaluate`-allow, cache-`allow`,
  trust-allow — and the deny short-circuit all still win first; `ask` only fires
  when the command is otherwise undecided *and* an `ask` gate matched):

  ```lua
  if command and PermissionRules.should_prompt(command) then
      return "ask"
  end
  return nil
  ```
- Return type becomes `"allow" | "deny" | "ask" | nil`. Update the annotation.
- **Interactive path unchanged.** `_try_auto_approve` handles only `allow`/`deny`
  explicitly and returns `false` for everything else, so `"ask"` falls through to
  the existing interactive prompt exactly as `nil` did. Add a comment; no logic
  change.

### 2. Scope to `auto` mode only

`permission_hook.evaluate` already base64-decodes the full PreToolUse hook JSON,
which includes `permission_mode` (`BaseHookInput.permission_mode`, `sdk.d.ts:164`,
typed `string`; runtime value is one of `PermissionMode`, `sdk.d.ts:2017`). No
shell change needed — read `payload.permission_mode`. The blocking-prompt
interception fires **only** when `permission_mode == "auto"`; every other mode
already resolves the `ask` per its own explicit contract, so the hook returns
`""` and lets the resolver handle it:

| mode | hook returns `""` for `ask` → resolver does | correct? |
|---|---|---|
| `auto` | classifier silently allows — **the bug** | intercept (below) |
| `default` | reaches `canUseTool` → plugin prompt fires once | ✓ prompts as today |
| `dontAsk` | denies (mode = "auto-deny anything that would prompt") | ✓ matches contract |
| `bypassPermissions` | allows (user opted out of all checks) | ✓ matches contract |
| `plan` / `acceptEdits` | per `internals.md` resolver map | out of scope |

So the verdict handling in `permission_hook.evaluate`:

| `decide` verdict | `permission_mode == "auto"` | otherwise |
|---|---|---|
| `"allow"` | `"allow"` | `"allow"` |
| `"deny"` | `"deny"` | `"deny"` |
| `"ask"` | **enqueue prompt, return `"pending"`** (see § 3) | `""` |
| `nil` | `""` | `""` |

Gating on `"auto"` also confines the interception to the one mode where the
outcome is surprising, and keeps the hook a no-op interposition everywhere else
even though it is registered for all sessions.

### 3. Enqueue-and-poll (no nvim-side blocking)

Per-call identity uses the hook input's `tool_use_id`
(`PreToolUseHookInput.tool_use_id`, `sdk.d.ts:2177`), unique per tool call.

- **`permission_hook.evaluate`** (auto + `ask`): synthesise an ACP
  `RequestPermission` from `tool_name`/`tool_input` (it already builds the
  `toolCall`), adding the standard `options` (`allow_once`, `allow_always`,
  `reject_once`, `reject_always`) so `PermissionFloat` renders and the `1..N`
  keymaps map. Enqueue it through the normal queue with a callback that stores
  the answer on the manager keyed by `(session_id, tool_use_id)`, then **return
  immediately** with the string `"pending"`. Because the verdict is already known
  to be `ask`, enqueue directly rather than re-running `_try_auto_approve`.
- **`permission_hook.poll`** (new RPC entry): decode the same payload, look up
  the stored answer by `(session_id, tool_use_id)`, return `"allow"` /
  `"deny"` / `"pending"`. Map the answered `optionId` → its option `kind` →
  `"allow"` (`allow_once`/`allow_always`) or `"deny"` (`reject_*` / `cancelled`
  / `<C-c>` abort). Clear the entry on a terminal answer.
- **`permission_hook.cancel`** (new RPC entry): dequeue/close the float and drop
  the pending entry — called by the shell on its poll deadline.
- **`permission_hook.sh`** re-sends the *same* base64 payload for each RPC (no
  shell-side JSON parsing):

  ```sh
  case "$verdict" in
      allow|deny) emit "$verdict" ;;
      pending)
          # poll until answered or the deadline (< SDK hook timeout)
          waited=0
          while [ "$waited" -lt "$DEADLINE" ]; do
              sleep 0.1; waited=$((waited + 1))
              ans=$(nvim --server "$AGENTIC_SOCK" --remote-expr \
                  "luaeval('require(\"agentic.permission_hook\").poll(_A)','${payload}')" 2>/dev/null) || break
              case "$ans" in allow|deny) emit "$ans"; break ;; esac
          done
          if [ -z "${ans:-}" ] || { [ "$ans" != allow ] && [ "$ans" != deny ]; }; then
              nvim --server "$AGENTIC_SOCK" --remote-expr \
                  "luaeval('require(\"agentic.permission_hook\").cancel(_A)','${payload}')" 2>/dev/null
              emit deny   # fail-closed: an unanswered explicit ask is not auto-executed
          fi
          ;;
      *) : ;;   # "" → no output → classifier
  esac
  ```

  Each poll RPC runs a trivial table lookup and returns instantly, so nvim
  returns to its main input loop between polls and the user's keypress reaches
  the float's keymaps. `$DEADLINE` is in tenths of a second (poll interval); keep
  it below the SDK hook timeout — see § 4.
- **State store.** The pending-answer table lives **on the `PermissionManager`
  instance** (per-tabpage, so per-session — multi-tabpage rule: no module-level
  shared state). Keyed by `tool_use_id`. `SessionRegistry.permission_manager_for_session`
  already resolves the right manager from `session_id`.

### 4. Hook timeout coordination (load-bearing)

The SDK runs each PreToolUse hook with a `timeout` in **seconds** (not ms;
`HookCallbackMatcher.timeout` / the settings-blob per-command `timeout` are both
documented "Timeout in seconds", `sdk.d.ts:775`, `sdk.d.ts:4828`), default **60
s**. If the shell poll loop outlasts it, the SDK kills the hook → no output →
classifier → auto-allow, i.e. the bug reappears. Required:

- Set a generous `timeout` (seconds) on the inline PreToolUse hook entry in
  `acp_client.lua`'s `build_claude_options` (the
  `_meta.claudeCode.options.settings.hooks` blob — see
  `PLAN-auto-mode-integration.md` § "Hook registration"). A human answer window
  wants minutes, e.g. 300.
- The shell `$DEADLINE` must be **strictly less** than that `timeout × 10` tenths,
  so the shell hits its own deadline (→ `cancel` + `emit deny`, fail-closed)
  *before* the SDK kills the hook (→ classifier, fail-open). Fail-closed is the
  safe side for an explicit `ask` the user did not answer.
- Spike task: confirm the maximum permitted hook timeout / whether it can be
  disabled — enforcement is in the compiled binary, the type layer only forwards
  `i.timeout`.

## Reentrancy

The `vim.wait` hazard is gone: `evaluate` enqueues and **returns immediately**,
so the hook RPC never holds nvim's loop open. This does reuse `add_request` (the
integration plan chose `decide`-direct to avoid enqueuing a modal mid-RPC), but
the concern there was a *blocking* nested modal — here the float opens
`enter=false` (non-blocking, no focus steal) and the RPC returns, exactly the
benign case the integration plan's reentrancy trace already analysed. Between
polls nvim runs its normal main loop: streaming chunks render, other queued
permission requests display in order, and the user answers via the standard
keymaps.

- An interactive prompt already `current` when the hook fires → the synthesised
  request queues behind it; the poll returns `"pending"` until the user works
  down to it.
- Parallel PreToolUse hooks (batched tool calls) → each shell process polls its
  own `tool_use_id`; prompts serialise through the one queue; each shell gets
  its own answer.

## Testing

- **Unit:** `should_prompt` truth table (concrete `ask` match → true; dynamic
  token → false; deny wins over ask; parse failure → false). `decide` verdict
  table gains the `ask` row (explicit-`ask` command → `"ask"`; unprovable →
  `nil`). Assert `_try_auto_approve` still prompts (returns `false`) for an
  `"ask"` verdict — the existing `permission_manager.test.lua:1188` ("prompts an
  ask command instead of rejecting") already covers the interactive path and must
  stay green.
- **Enqueue/poll:** `evaluate` (auto + `ask`) returns `"pending"` and registers a
  pending entry; firing the stored callback with each `optionId` makes `poll`
  return the mapped `"allow"`/`"deny"` and clears the entry; `poll` returns
  `"pending"` until answered; `cancel` dequeues and drops the entry. Drive the
  callback in-test — no real keypress needed.
- **Mode gate:** `evaluate` returns `""` for `"ask"` when `permission_mode ~=
  "auto"`, and returns `"pending"` when `== "auto"`.
- **E2e:** a real auto-mode `git commit` reaches the hook, opens the float; the
  shell poll loop picks up the answered verdict and maps it to
  `permissionDecision`.
