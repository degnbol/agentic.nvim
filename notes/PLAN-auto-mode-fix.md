# PLAN: honour explicit `ask` gates under auto mode

Status: reviewed spec. Extends `PLAN-auto-mode-integration.md`.

## Background

Under auto mode, a command that matches a structured `ask` gate (e.g.
`git commit`: `{"positionals":["commit"]}` in `git.ask` of the bundled
`lua/agentic/permissions.json`) is auto-allowed by the SDK classifier without a
prompt.

Root cause: `PermissionManager:decide` returns `"allow"|"deny"|nil` (plus
deciders) and folds two outcomes into `nil`:

- **explicit `ask`**: a gate matched; the user wants a prompt.
- **defer**: no rule matched; the classifier's legitimate residue.

`PermissionRules.should_auto_reject` is concrete-deny-only, and
`PermissionRules.evaluate` returns `ok = false` both for "an `ask` gate blocked
approval" and for "no allow rule matched". `permission_hook.evaluate` maps `nil`
to `""`, `hooks/permission_hook.sh` emits no `permissionDecision`, and the call
goes to the classifier (`~/.claude/skills/claude/references/internals.md`
§ "PreToolUse decision vs the permission resolver": no decision, resolver
handles it; in auto mode the resolver is the classifier).

On the interactive (`canUseTool`) path both `nil` outcomes reach the same
prompt, so only the hook path loses the distinction.

### Rejected alternatives

- **Map `ask` to hook `deny`.** `deny` is a hard reject (`tool.call()` never
  runs, an `is_error` `tool_result` goes to the model). The agent could never
  commit in auto mode.
- **Another `permissionDecision`.** `HookPermissionDecision` is
  `'allow' | 'deny' | 'ask' | 'defer'` (`sdk.d.ts`). In auto mode hook `ask`
  goes to the classifier; `defer` is print-mode-only.
  `PreToolUseHookSpecificOutput` has only `permissionDecision`,
  `permissionDecisionReason`, `updatedInput`, `additionalContext`: no mode lever.
- **Flip the session out of auto mode from the hook.** The only lever is an
  async `session/set_mode` request, handled on the SDK loop that is blocked on
  this tool call, so it lands after the resolver has read the mode. It is also
  session-global and needs restore bookkeeping.
- **Block inside nvim (`vim.wait`) for the answer.** `vim.wait` pumps libuv but
  does not dispatch mapped keys, and the answer arrives through the float's
  buffer-local keymaps. Every prompt would time out. The waiting goes in the
  hook shell process instead, and every RPC into nvim returns at once.

## Changes

On an explicit `ask` in auto mode, the hook RPC queues the plugin's normal
permission float and returns at once. The hook shell process then polls nvim
until the user answers, and emits the answer as the hook's `allow`/`deny`.

### 1. `ask` as a distinct ladder verdict

`lua/agentic/utils/permission_structured.lua`:

- `M.ask_leaf(entries, parsed) -> boolean`: true iff some `ask` gate of the
  leaf's relevant entries holds under concrete matching. Use the gate semantics
  of the `ask` clause of `decide_leaf` (`gate_may`, so `unless` and
  `option_values` apply), over a concrete context:
  `build_exist_ctx(args, {}, false, ...)` and `forall_getter(args, {}, arity)`.
  Do **not** copy `deny_leaf`'s plain `gate_matches_existential`: bundled `ask`
  gates use `unless` (`gh api` unless `-X GET`, `curl -o` unless `/dev/null`),
  and plain matching would prompt for those.

`lua/agentic/utils/permission_rules.lua`:

- `M.should_prompt(command, config_dir) -> boolean`: true iff an executed leaf
  concretely matches an `ask` gate (`PermissionStructured.ask_leaf`) or a glob
  pattern from `M.get_settings_patterns("ask", config_dir)` (but see § 4).
  Concrete-only and fail-closed-to-false (no parser, parse error, over-long
  command), like `should_auto_reject`. A dynamic token (`git $x`) goes to the
  classifier: the same residual the concrete-only deny pass has.
- Do not copy the reject traversal. Generalise `reject_walk` /
  `command_is_denied` over a gate: the ctx carries the glob patterns of one list
  and the leaf predicate (`deny_leaf` or `ask_leaf`). `should_auto_reject` and
  `should_prompt` both call the one walk; `should_prompt` drops the source.
- Alternative considered: make `evaluate`'s walk also report an ask match.
  Rejected: it keeps the hot approve path unchanged; the separate pass runs only
  on the undecided branch.

`lua/agentic/ui/permission_manager.lua`, `PermissionManager:decide`: add an
`ask` branch immediately before the final `return nil, nil`. Every earlier
verdict still wins: the concrete-deny pass, the allow/reject-always cache,
`auto_approve_kinds`, `evaluate` allow, grant scopes.

```lua
if command and PermissionRules.should_prompt(command, self._get_config_dir()) then
    return "ask", nil
end
return nil, nil
```

Update the return annotation to `"allow"|"deny"|"ask"|nil`. Deciders stay nil
for `ask`; `_complete_request` records `prompt-allow`/`prompt-reject` when the
user answers.

`_try_auto_approve` handles only `allow`/`deny`, so `"ask"` reaches the
interactive prompt exactly as `nil` did. No logic change.

### 2. Auto mode only

`permission_hook.evaluate` already decodes the full hook input. Read
`payload.permission_mode` (`BaseHookInput.permission_mode`, optional `string`;
values from `PermissionMode`). When the field is absent, fall back to the
session's `config_options:current_mode_id()`. Intercept only when the mode is
`"auto"`. Every other mode resolves a hook no-decision by its own contract:

| mode | hook returns `""`, the resolver does | correct |
|---|---|---|
| `auto` | classifier allows: **the bug** | intercept |
| `default` | `canUseTool`, plugin prompt | yes |
| `dontAsk` | deny | yes |
| `bypassPermissions` | allow | yes |
| `plan` / `acceptEdits` | per `internals.md` resolver map | out of scope |

Verdict mapping in `permission_hook.evaluate`:

| `decide` verdict | mode `auto` | other modes |
|---|---|---|
| `"allow"` | `"allow"` | `"allow"` |
| `"deny"` | `"deny"` | `"deny"` |
| `"ask"` | queue prompt, return `"pending"` (§ 3) | `""` |
| `nil` | `""` | `""` |

### 3. Queue and poll

The call identity is `PreToolUseHookInput.tool_use_id`. claude-agent-acp uses it
as the ACP `toolCallId`; `permission_hook.evaluate` already relies on this for
`record_deciders`. The session comes from the existing
`SessionRegistry.session_for_acp_id(payload.session_id)`, the manager from its
`permission_manager` field.

State: a pending-answer table on the `PermissionManager` instance
(`hook_answers: table<string, "pending"|"allow"|"deny">`, keyed by
`tool_use_id`): per session, as the session-isolation rule requires. `clear()`
empties it.

`lua/agentic/permission_hook.lua`:

- `M.evaluate(b64)`, auto + `ask`: build an `agentic.acp.RequestPermission` with
  `sessionId = payload.session_id`, `toolCall.toolCallId = payload.tool_use_id`
  (not the current placeholder `"hook"`: the float anchor, the tool-call hold,
  the unapproved-command highlight and `record_deciders` all look up the tool
  call by this id), and options `allow_once`, `allow_always`, `reject_once`,
  `reject_always` (option id = kind). Set `hook_answers[id] = "pending"`, then
  call `SessionManager:_on_request_permission(request, callback)` (rename it to
  public `request_permission`, since a second module now calls it), not
  `pm:add_request` directly: that method also stops the status indicator, rings
  the attention signal and fires the `on_permission_request` user hook, which
  matter most in auto mode, where the user is likely not watching. The callback
  maps option kind `allow_*` to `"allow"`, and `reject_*` or a nil option id
  (cancel) to `"deny"`. Return `"pending"`. `add_request` re-runs
  `_try_auto_approve`; `decide` is deterministic and returns `"ask"` again, so
  the request queues. If it did auto-resolve, the callback has already stored
  the answer and `poll` returns it.
- `M.poll(b64) -> "allow"|"deny"|"pending"`: look up `hook_answers` by
  `tool_use_id`; drop the entry on a terminal answer. An unknown id returns
  `"deny"` (manager cleared, nvim restarted): fail-closed.
- `M.cancel(b64)`: `pm:remove_request_by_tool_call_id(tool_use_id)` (closes the
  float or dequeues; its nil callback stores `"deny"`), then drop the entry.

`hooks/permission_hook.sh`: add an `emit <verdict>` helper for the two existing
`printf` lines, and a `pending)` branch that re-sends the same base64 payload
(no shell-side JSON parsing):

```sh
pending)
    i=0
    while [ "$i" -lt "$POLLS" ]; do
        sleep "$POLL_INTERVAL"; i=$((i + 1))
        ans=$(nvim --server "$AGENTIC_SOCK" --remote-expr \
            "luaeval('require(\"agentic.permission_hook\").poll(_A)', '${payload}')" 2>/dev/null) || break
        case "$ans" in allow|deny) emit "$ans"; exit 0 ;; esac
    done
    nvim --server "$AGENTIC_SOCK" --remote-expr \
        "luaeval('require(\"agentic.permission_hook\").cancel(_A)', '${payload}')" >/dev/null 2>&1
    emit deny   # fail-closed: an unanswered explicit ask does not run
    ;;
```

Each poll is a table lookup, so nvim returns to its main loop between polls and
the float's keymaps get the keypress. Each poll spawns an nvim client process,
so use `POLL_INTERVAL=0.5`, not 0.1 (fractional `sleep` works on macOS and GNU
coreutils).

### 4. Hook timeout and settings `ask` rules

- Set an explicit `timeout` (seconds: `HookCallbackMatcher.timeout` and the
  per-command `timeout` are both seconds) on the permission hook entry in
  `build_claude_options`
  (`lua/agentic/acp/adapters/claude_agent_acp_adapter.lua`):
  `{ type = "command", command = PERMISSION_HOOK, timeout = 300 }`. If the SDK
  kills the hook first, no output reaches it and the classifier allows: the bug
  comes back.
- `POLLS * POLL_INTERVAL` must be strictly less than that timeout, so the shell
  reaches its own deadline (`cancel`, `deny`) before the SDK kills it.
- Spike: confirm the maximum hook timeout the compiled binary accepts.
- Spike: in auto mode, does a settings.json `ask` rule for Bash reach
  `canUseTool`? `internals.md` says a hook `allow` short-circuits only when no
  settings `ask` rule matches.
  - If yes: glob `ask` patterns already prompt. `should_prompt` must match
    structured `ask` gates only, or the user gets two prompts.
  - If no: a user `allow` from the hook does not stick for a glob-`ask` command
    (the classifier still runs). Keep glob patterns in `should_prompt` for the
    fail-closed `deny` side.

## Reentrancy

`evaluate` queues and returns at once, so the hook RPC never holds nvim's loop.
The integration plan kept the hook away from `add_request` because of a nested
*blocking* modal. Here the float opens with `enter=false` and the RPC returns:
the benign case the integration plan's § "Reentrancy" trace analysed.

- An interactive prompt is already `current_request`: the hook request queues
  behind it; `poll` returns `"pending"` until the user reaches it.
- Parallel PreToolUse hooks (batched tool calls): each shell polls its own
  `tool_use_id`; prompts serialise through the one queue.
- The user cancels the turn: `cancel_requests` resolves the hook request with
  nil, so the entry becomes `"deny"`. If the SDK has already killed the hook,
  nobody polls the entry; `clear()` drops it.

## Testing

- **`should_prompt`:** a concrete `ask` match is true; a dynamic token is false;
  an `unless` exclusion (`gh api -X GET`) is false; a parse failure is false; a
  wrapped ask (`timeout 5 git commit`) is true.
- **`decide`:** an explicit-ask command returns `"ask"`; deny wins over ask; an
  allow-always cached command returns `"allow"`; an unprovable command returns
  `nil`. The existing `permission_manager.test.lua` test "prompts an ask command
  instead of rejecting" covers the interactive path and must stay green.
- **`permission_hook`:** `evaluate` (auto + ask) returns `"pending"` and queues
  a request whose `toolCallId` is the `tool_use_id`; calling the stored callback
  with each option id makes `poll` return the mapped verdict and drop the entry;
  `poll` returns `"pending"` before an answer and `"deny"` for an unknown id;
  `cancel` dequeues and drops the entry.
- **Mode gate:** `evaluate` returns `""` for `"ask"` when `permission_mode` is
  not `"auto"`, `"pending"` when it is, and uses the session mode when the field
  is absent.
- **E2e:** an auto-mode `git commit` opens the float; the answer reaches the
  shell poll loop and becomes the `permissionDecision`.
