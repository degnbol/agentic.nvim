# PLAN: deterministic permission ladder as a PreToolUse hook, classifier as fallback

Status: **grilled, forks resolved; Phase 1 complete and verified live** (the
`decide` refactor, `session_id → SessionManager` lookup, RPC module + hook
script, `AGENTIC_SOCK` at spawn, and the inline hook registration in
`session/new` **and** `session/load` `_meta` are all done and unit-tested — see
"Single source of truth", "Session routing", "Transport", "Hook registration",
and "Phasing" below). The live bridge chain is confirmed: a real auto-mode Bash
call reached the hook, matched its session's `PermissionManager`, ran `decide`,
and fell through to the classifier as `undecided` — proving `AGENTIC_SOCK`
propagation and `CLAUDE_CODE_SESSION_ID == session_id` routing end-to-end.
Merge-asymmetry and
permission-flow claims are sourced from the `acp` skill's
`references/claude-agent.md`; the env/session-id **routing** facts in "Resolved
by source" are compiled-binary spike results **not yet in that reference** (they
must be recorded there before an implementer can re-derive the socket routing).
The two Phase-0 source verifications the earlier draft worried about are now
**done** (see "Resolved by source" below).

## Goal

Let a user opt a session into Claude's **auto** mode so the SDK's LLM
**classifier** can auto-allow commands that are *obviously* safe to a reader but
beyond static proof (e.g. a `print`-heavy python one-liner) — while keeping the
plugin's **deterministic** permission ladder (`PermissionManager` +
`permission_rules.lua` + `permissions.json`) as the **first** gate.

The classifier is non-deterministic, higher-latency, and costs real money, so it
must be **opt-in** and must only ever judge the **residue** the deterministic
ladder leaves undecided. In practice that residue is:

- **Bash**: commands neither in the user's settings-`allow` list nor provable by
  `permissions.json`.
- **Write/Edit outside `/trust` scope**: a genuinely useful place for a judgment
  call.

Everything else (Read/Grep/Glob/WebFetch/WebSearch/MCP) is already auto-allowed
by SDK-level settings-`allow` rules, which resolve *before* the classifier and
survive auto mode — so it never reaches the classifier and needs no hook.

## Why a PreToolUse hook is the only viable shape

Under auto mode the classifier lives *inside* the SDK permission resolver: an
SDK-internal classifier resolves each otherwise-`ask` call to allow/deny
*before* `canUseTool` runs (`acp` skill `references/claude-agent.md` §
"Permission flow"). The plugin's existing client-side ladder runs at
`canUseTool` (ACP `request_permission`), which auto mode reaches **only when the
classifier abstains** — i.e. *after* the paid call. So the client path cannot
run first. The one interposition point ahead of the resolver is a **PreToolUse
hook**.

The hook is registered **without any settings file** — via
`_meta.claudeCode.options.settings.hooks` at `session/new`, an inline `Settings`
blob loaded into the SDK's flag tier (`--settings`-equivalent). Note the *other*
`_meta` channel, `options.hooks`, silently drops JSON command hooks (it expects
`HookCallback` functions), but `options.settings` does not — it carries the
settings-file `{type:"command",…}` shape verbatim. Verified end-to-end
(claude-agent.md § "Registering a command hook without a settings file").

## Decision mapping (ladder verdict → hook output)

The hook runs the same deterministic ladder and maps its verdict onto the
PreToolUse `permissionDecision`, exploiting the `ev6` merge asymmetry (`claude`
skill `references/internals.md` § "PreToolUse decision vs the permission
resolver"):

| ladder verdict | hook `permissionDecision` | effect under auto mode |
|----------------|---------------------------|------------------------|
| reject (`should_auto_reject` / reject-always / settings deny) | `deny` | **unconditional** short-circuit — classifier never runs (branch a) |
| allow (read-only / structural safe / `/trust` / allow-always) | `allow` | short-circuits classifier when unobstructed (branch f) |
| undecided | *(no output)* | falls through to the classifier (branch b) |

Never emit `defer` — it is print-mode-only and ignored in interactive ACP
(same merge reference).

## Resolved by source (were the Phase-0 unknowns)

- **The allow path short-circuits for our tools.** `ev6` branch (c) — the one
  that would force an allow hook back into the classifier — depends on
  `requireCanUseTool` (`A`) and `requiresUserInteraction` (`$`). Against the
  compiled SDK binary: `requireCanUseTool` is **never set on the normal tool
  path** (only in the `"speculation"` fork), and `requiresUserInteraction` is
  defined on **only two tools** (AskUserQuestion, ExitPlanMode) — not Bash, not
  Write/Edit. So for every tool we match, branch (c) is skipped; an unobstructed
  `allow` reaches branch (f) and bypasses the classifier. Only a settings
  `ask`/`deny` rule or the SDK's built-in safety check (`Z2H`, branches d/e)
  sends an allowed command onward — which is the desired behaviour anyway.
- **`AGENTIC_SOCK` reaches the hook.** *(Spike result — not in claude-agent.md;
  record it there.)* `createSession` builds the SDK query with
  `env: {...process.env, ...}` and hooks spawn with `{...process.env, ...}`, so
  env set at the bridge spawn (nvim → bridge → SDK CLI → hook) propagates. The
  SDK also documents `${ENV_VAR}` substitution in hook command strings.
- **`CLAUDE_CODE_SESSION_ID` == the ACP `session_id`.** *(Spike result — not in
  claude-agent.md; the entire socket-routing scheme rests on this, so record it
  there.)* The bridge mints the
  session id (`randomUUID`), feeds it to the SDK as `resume:`, and the SDK echoes
  it back as `message.session_id` on the notifications the client keys on.
  `CLAUDE_CODE_SESSION_ID` (in the hook env) is that same string, so the hook
  routes to the right `PermissionManager` with no translation.

## Single source of truth — refactor, don't fork

The trust scope, allow-always/reject-always cache, and git-clean-hunk
recoverability check live **above** `permission_rules` in `PermissionManager`
(`_try_auto_approve`, lines ~300–395). The hook must run that whole ladder, not
just the analyzer.

- Extract a **pure** `PermissionManager:decide(kind, tool_call, diff) →
  "allow" | "deny" | nil` that returns a verdict and performs **no** ACP-side
  effect (no `callback`, no `auto_approve`/`auto_reject`). **Done** — `decide`
  plus a thin `_try_auto_approve` wrapper land in `permission_manager.lua`, with
  unit tests for the verdict table. (Routing takes `session_id` before `decide`
  — see § "Session routing" — so it isn't a `decide` parameter.)
- The existing `canUseTool` path and the hook-RPC entry **both** call `decide`.
  Parity holds by construction — not by a test that can rot.
- `decide` must **not** read `message_writer.tool_call_blocks` (the tracker may
  be unpopulated at hook time). Three tracker reads had to move out to the
  wrapper, which passes their results in:
  - **`kind`** — the claude hook input carries a reliable kind. (The tracker was
    only an opencode re-kind fallback.)
  - **`command`** — read from `tool_call.rawInput.command`. (Opencode's
    `metadata:{}` fallback is injected by the wrapper before delegating.)
  - **`diff`** — the trust-scope path (`_check_trust` → `_build_kind_args`) read
    `tracker.diff`. It's derivable from `rawInput`, so it's now a threaded
    parameter: the `canUseTool` caller passes `tracker.diff` unchanged; the
    **hook caller must reconstruct it from `rawInput`** (open item for the hook
    script). Scope: replicate the claude adapter's `edit`-kind branch — the hook
    receives a raw tool **name** + `tool_input`, so it must map name → kind and
    handle both shapes (`Edit` uses `old_string`/`new_string`/`replace_all`;
    `Write`/`create` uses `content` with no `old_string`). Confirm a `Write`
    diff still drives the trust `is_pure_addition` path.

## Session routing

`PermissionManager` is per-tabpage (`session_manager.lua:264`; `SessionManager`
keyed by `tab_page_id` in `SessionRegistry`), so `_trust_scope`/`_always_cache`
are genuine per-session state. **Done** — `SessionRegistry.permission_manager_for_session`
scans the tab-keyed map for a matching `self.session_id` and returns that
manager's `PermissionManager`. Global across providers as required (one bridge
per provider, all sharing `$AGENTIC_SOCK`).

## Hook matcher

`Bash|Write|Edit` (tool **names**). Rationale:

- **Bash** — structural/compound analysis beyond settings globs, and the deny
  floor (the classifier could otherwise allow a `permissions.json`-denied
  command).
- **Write/Edit family** — `/trust repo` short-circuit; settings only auto-allow
  `/tmp` writes, so repo writes would otherwise hit the classifier.
- **Excluded**: Read/Grep/Glob/WebFetch/WebSearch/MCP — already SDK-allowed via
  settings-`allow`, which survives auto mode. Matching them would only fire a
  redundant RPC on the most frequent tools.
- **Also excluded, `MultiEdit`/`NotebookEdit`**: the plugin has no kind mapping
  for either (the claude adapter derives `diff` only for `kind == "edit"`), so
  `decide` returns `nil` for them regardless — a wasted RPC. Add them only if a
  future spike ports their kind derivation into the hook script.

## Transport: RPC into the live nvim

`permission_rules.lua` needs a tree-sitter parse tree, and `decide` needs live
`/trust`/cache/git state — both already loaded in the running nvim. So the hook
RPCs in rather than reconstructing state. **Done** — `hooks/permission_hook.sh`
+ `lua/agentic/permission_hook.lua`:

```
nvim --server $AGENTIC_SOCK --remote-expr "luaeval('...evaluate(_A)', 'BASE64')"
```

- The hook reads its stdin JSON (`{session_id, tool_name, tool_input}`),
  base64-encodes it (sidesteps all shell/vimscript quoting — base64 is
  single-quote-safe), and passes it as luaeval's `_A`. `permission_hook.evaluate`
  decodes it, maps the SDK tool **name** → ACP kind (`Bash`→execute,
  `Edit`/`Write`→edit — Write is `edit`, not `create`, to match the claude
  adapter's whole-file-`content` diff), reconstructs the `edit` diff from
  `old_string`/`new_string`/`content`, and calls `decide` **directly** (never
  `add_request` — no nested modal, see § "Reentrancy"). The verdict →
  `permissionDecision` mapping lives in the shell `case`.
- `AGENTIC_SOCK = v:servername`, set in `acp_transport.lua`'s spawn env
  (falls back to `serverstart()` if `v:servername` is empty). `AgentInstance` is
  keyed by **provider**, so a multi-provider nvim spawns multiple bridges — all
  inheriting the same `AGENTIC_SOCK`. Routing still works (the hook passes
  `session_id`); the lookup is **global across providers** (see § "Session
  routing").
- **Self-scoping**: registration is per-session via `session/new` `_meta`, so the
  hook exists *only* for sessions this plugin creates — a plain `claude` CLI run
  or another frontend never receives it. The hook's first step is still *if
  `$AGENTIC_SOCK` unset → exit 0, no output* as belt-and-braces, but scoping no
  longer depends on it. No file, no marker, no per-session rewrite.
- **Fail-open**: any RPC error/timeout, unknown tool, missing session, or empty
  verdict → **no output** (fall through to the classifier), never a spurious
  allow.
- The standalone `ltreesitter` option is off the table: it cannot see live
  `/trust`/git state without reimplementing this RPC anyway.

## Hook registration (no file)

The `PreToolUse` hook is injected inline at `session/new` **and** `session/load`
(a resumed session can switch to auto mode too) via a shared
`build_claude_options` helper in `acp_client.lua` — **nothing is written to
disk**:

```lua
_meta.claudeCode.options.settings = {
  hooks = { PreToolUse = { {
    matcher = "Bash|Write|Edit",
    hooks = { { type = "command", command = "<abs>/hooks/permission_hook.sh" } },
  } } },
}
```

- **No merge/clobber/symlink/read-only/JSON-validation concerns** — those existed
  only for a shared on-disk `settings.local.json`. In-memory flag-tier settings
  carry no such hygiene surface.
- **No gitignore handling, no per-folder trace, no user-config modification.**
- **Lifecycle**: rebuilt from constants on every `session/new`; dies with the
  session. `settingSources` files (user/project/local) still merge underneath, so
  a user's own hooks are untouched.
- **Caveat**: passing `settings` suppresses the bridge's `CLAUDE_MODEL_CONFIG`
  modelConfig injection (claude-agent.md § "Registering a command hook without a
  settings file"). Irrelevant unless Bedrock model overrides are in use; include
  `modelOverrides`/`availableModels` in the same blob if so.

## Enabling auto mode (opt-in, no new mode code)

`auto` already appears in the existing mode selector (`<localLeader>m` →
`AgentConfigOptions:show_mode_selector` → `vim.ui.select` over `availableModes`)
when the model supports it (claude-agent.md § "Permission mode over ACP"). No
persisted `defaultMode: "auto"` — that leaks to plain `claude` CLI runs in the
cwd and isn't opt-in.

- The Haiku **clamp** is handled for free: `applySessionMode` throws if `auto`
  isn't in `availableModes`, so the selector simply won't offer it.
- `Config` default stays non-auto; a user may set their own default to `auto`.

## Remaining risks (verify, not design)

1. **Latency** of the per-call RPC — now includes Write/Edit, higher frequency
   than the original Bash-only framing. Measure in the spike; it gates nothing
   architectural, only whether (b) is fast enough as-is.

## Reentrancy

The hook (a grandchild of nvim) blocks synchronously on `--remote-expr` back
into that same nvim. The earlier framing ("nvim sits idle") is **wrong for the
window that matters**: `decide`'s trust path shells out via the blocking
`wait()` on a `vim.system(...)` handle (`git_files.lua`), and that call **pumps
the libuv loop** while it waits. So `decide` *creates* a window in which the ACP
transport's `stdout` callback and queued `vim.schedule` callbacks fire — during
a synchronous hook RPC.

The loop-pumping is **kept on purpose**: it is what keeps the editor responsive
during the git call. A hard-blocking `vim.fn.system` would close the reentrancy
window but freeze the whole editor for the git call's duration (visible on a
slow/cold/network-fs repo, and a straight regression on the interactive
`canUseTool` path) — rejected.

Since the pump stays, the design must be safe against what the pump can fire.
The candidate hazard is a `session/request_permission` arriving mid-`decide` →
`add_request` → `_process_next` opening a `permission_float` **nested inside**
the synchronous hook RPC. **Traced (2026-07-02) — this is benign, not a
deadlock:**

- `on_request_permission` reaches the client deferred, via `vim.schedule`
  (`acp_client.lua:766`), and `wait()`-pumping does run scheduled callbacks — so
  the reentrant path is real.
- But `permission_float:open` (`permission_float.lua:254`) opens with
  `nvim_open_win(bufnr, false, …)` — **`enter=false`** — and returns immediately
  (no `getchar`/`vim.wait`/`vim.ui.select`; input arrives later via keymaps). It
  neither blocks nor steals focus.
- Lua is single-threaded: the pump runs each scheduled callback **to completion
  atomically** between iterations, so the reentrant `add_request` can't corrupt
  the queue mid-function. And the hook-path `decide` is **read-only w.r.t. the
  queue**, so a concurrent `add_request` can't corrupt what `decide` reads.

So the reviewer's "blocking" severity doesn't hold — the assumed nested modal
input loop can't occur. Design:

- **Required:** the hook RPC handler **calls `decide` directly** and returns the
  verdict string — it never goes through `add_request`/`_process_next`, so the
  hook never enqueues or opens its own modal.
- **Defensive (optional, cheap):** a **per-instance** guard on `PermissionManager`
  (not module-level — multi-tabpage rule) set for the duration of a hook-RPC
  `decide`; while set, `_process_next` **defers** opening a modal, and the queue
  is drained on RPC return. This is *not* load-bearing (the float is non-blocking
  either way) — it only makes an unrelated float appear right after the RPC
  rather than flickering open during it, keeping `current_request` transitions at
  a predictable time. Drop it if it complicates the queue logic.

Blocking-`wait()` surface, for the record (all kept — pumping, not eliminated):
- **`get_git_root`** — **(done)** replaced with `vim.fs.root(cwd, ".git")` (pure
  fs walk, no subprocess; the old impl was *uncached* so this removed a
  guaranteed `git rev-parse` per call). Incidental win, not the reentrancy fix.
- **`is_tracked`** — mtime-cached; warm calls are free.
- **`diff_hunks`** — one `git diff` per trust-scoped edit, loop-pumping. Kept;
  the pump is safe per the trace above, so no need to remove or cache the call.

## Phasing

- **Phase 1 (spike):** `decide` refactor **(done)**; `session_id →
  SessionManager` lookup **(done)**; RPC handler calling `decide` directly
  **(done)** — hook calls `evaluate` → `decide`, no `add_request`, so the
  optional defensive `_process_next` deferral (§ "Reentrancy") is unneeded and
  skipped; hook script (self-scoping + fail-open + `diff` reconstruction from
  `rawInput`) **(done)**; `AGENTIC_SOCK` at spawn **(done)**. (The
  `<localLeader>m` mode-switch keymap already landed separately, so no keymap
  work remains.) Inline hook registration in `session/new` + `session/load`
  `_meta.claudeCode.options.settings.hooks` **(done)** — § "Hook registration
  (no file)". Live e2e **(done)** — a real auto-mode Bash call was routed
  through the hook and logged `undecided (falls through to classifier)`,
  confirming socket propagation, session-id routing, and `decide` all fire
  end-to-end. `permission_hook.evaluate` logs its verdict per call (gated by
  `Config.log`) so allow/deny/undecided/unmatched/no-session are all
  distinguishable at runtime. **Phase 1 complete.**
- **Phase 2 (productionise):** config flag to enable, failure-mode coverage,
  multi-nvim same-cwd check.
- **Phase 3 (measure):** RPC latency (risk 1); only revisit transport if
  unacceptable.

## Testing

- **Unit:** `decide` verdict table (read-only/skill → allow, deny-rule → deny,
  cache hits, unprovable → nil) **done** in `permission_manager.test.lua`. The
  RPC glue (name→kind map, edit-diff reconstruction, fail-open on unknown
  tool / missing session / undecodable input, verdict passthrough) is **done**
  in `permission_hook.test.lua`. The verdict → `permissionDecision` mapping
  lives in the shell `case` and is exercised by the e2e driver.
  `canUseTool`/hook parity is structural (one `decide`, two callers) rather than
  a separate assertion.
- **E2e:** the driver-harness assertions in Phase 1.
