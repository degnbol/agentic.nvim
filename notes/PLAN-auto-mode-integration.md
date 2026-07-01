# PLAN: deterministic permission ladder as a PreToolUse hook, classifier as fallback

Status: **grilled, forks resolved.** Pairs with the source dump in
`auto-mode-permission-ordering.md` (same dir) — it holds the citations for every
claim referenced here (`§N`). This plan supersedes the earlier draft; the two
Phase-0 source verifications it worried about are now **done** (see "Resolved by
source" below).

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

Under auto mode the classifier lives *inside* the SDK permission resolver at
**step 5** of the tool pipeline (dump §2). The plugin's existing client-side
ladder runs at `canUseTool` (ACP `request_permission`), which auto mode reaches
**only when the classifier abstains** — i.e. *after* the paid call. So the
client path cannot run first. The one interposition point ahead of the resolver
is a **PreToolUse hook at step 4** (dump §3), and command hooks must come from a
settings file the SDK reads via `settingSources` — the `_meta` options channel
silently ignores JSON command hooks (dump §6).

## Decision mapping (ladder verdict → hook output)

The hook runs the same deterministic ladder and maps its verdict onto the
PreToolUse `permissionDecision`, exploiting the `ev6` merge asymmetry (dump §3):

| ladder verdict | hook `permissionDecision` | effect under auto mode |
|----------------|---------------------------|------------------------|
| reject (`should_auto_reject` / reject-always / settings deny) | `deny` | **unconditional** short-circuit — classifier never runs (branch a) |
| allow (read-only / structural safe / `/trust` / allow-always) | `allow` | short-circuits classifier when unobstructed (branch f) |
| undecided | *(no output)* | falls through to the classifier (branch b) |

Never emit `defer` — it is print-mode-only and ignored in interactive ACP
(dump §3).

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
- **`AGENTIC_SOCK` reaches the hook.** `createSession` builds the SDK query with
  `env: {...process.env, ...}` and hooks spawn with `{...process.env, ...}`, so
  env set at the bridge spawn (nvim → bridge → SDK CLI → hook) propagates. The
  SDK also documents `${ENV_VAR}` substitution in hook command strings.
- **`CLAUDE_CODE_SESSION_ID` == the ACP `session_id`.** The bridge mints the
  session id (`randomUUID`), feeds it to the SDK as `resume:`, and the SDK echoes
  it back as `message.session_id` on the notifications the client keys on.
  `CLAUDE_CODE_SESSION_ID` (in the hook env) is that same string, so the hook
  routes to the right `PermissionManager` with no translation.

## Single source of truth — refactor, don't fork

The trust scope, allow-always/reject-always cache, and git-clean-hunk
recoverability check live **above** `permission_rules` in `PermissionManager`
(`_try_auto_approve`, lines ~300–395). The hook must run that whole ladder, not
just the analyzer.

- Extract a **pure** `PermissionManager:decide(session_id, kind, tool_call) →
  "allow" | "deny" | nil` that returns a verdict and performs **no** ACP-side
  effect (no `callback`, no `auto_approve`/`auto_reject`).
- The existing `canUseTool` path and the hook-RPC entry **both** call `decide`.
  Parity holds by construction — not by a test that can rot.
- `decide` must **not** read `message_writer.tool_call_blocks` (the tracker may
  be unpopulated at hook time). The claude hook input carries a reliable `kind`;
  pass it in. (The tracker was only an opencode kind-fallback — irrelevant on the
  claude-only hook path.)

## Session routing

`PermissionManager` is per-tabpage (`session_manager.lua:264`; `SessionManager`
keyed by `tab_page_id` in `SessionRegistry`), so `_trust_scope`/`_always_cache`
are genuine per-session state. Add a `session_id → SessionManager` lookup (the
registry is tab-keyed today; each manager already holds `self.session_id`).

## Hook matcher

`Bash|Write|Edit|MultiEdit|NotebookEdit` (tool **names**). Rationale:

- **Bash** — structural/compound analysis beyond settings globs, and the deny
  floor (the classifier could otherwise allow a `permissions.json`-denied
  command).
- **Write/Edit family** — `/trust repo` short-circuit; settings only auto-allow
  `/tmp` writes, so repo writes would otherwise hit the classifier.
- **Excluded**: Read/Grep/Glob/WebFetch/WebSearch/MCP — already SDK-allowed via
  settings-`allow`, which survives auto mode. Matching them would only fire a
  redundant RPC on the most frequent tools.

## Transport: RPC into the live nvim

`permission_rules.lua` needs a tree-sitter parse tree, and `decide` needs live
`/trust`/cache/git state — both already loaded in the running nvim. So the hook
RPCs in rather than reconstructing state:

```
nvim --server $AGENTIC_SOCK --remote-expr 'luaeval(...)'   # passes {session_id, tool_name, tool_input}
```

- `AGENTIC_SOCK = v:servername`, set in `acp_transport.lua`'s spawn env
  (fall back to `serverstart()` if `v:servername` is empty). One agent process
  per nvim (`agent_instance.lua:4`), so one socket covers all its sessions.
- **Self-scoping**: the hook's first step is *if `$AGENTIC_SOCK` unset → exit 0,
  no output*. A plain `claude` CLI run in the same cwd never gets the var, so the
  hook no-ops for it. No marker file, no per-session rewrite.
- **Fail-open**: any RPC error/timeout → **no output** (fall through to the
  classifier), never a spurious allow.
- The standalone `ltreesitter` option is off the table: it cannot see live
  `/trust`/git state without reimplementing this RPC anyway.

## The settings-file artifact

`{cwd}/.claude/settings.local.json` (gitignored by convention). Because the hook
reads its socket from env and self-disables when absent, the file content is
**static and write-once** — no per-session mutation:

- **Merge, don't clobber** existing `settings.local.json` / hooks. Validate JSON.
  Handle the file being a symlink / read-only.
- Content = one `PreToolUse` hook, matcher above, `command` pointing at the hook
  script (absolute path), `${AGENTIC_SOCK}` read from env.
- **Lifecycle**: idempotent content → safe to leave in place; re-assert on
  session start.

## Enabling auto mode (opt-in, no new mode code)

`auto` already appears in the existing mode selector (`<localLeader>m` →
`AgentConfigOptions:show_mode_selector` → `vim.ui.select` over `availableModes`)
when the model supports it (dump §5). No persisted `defaultMode: "auto"` — that
leaks to plain `claude` CLI runs in the cwd and isn't opt-in.

- The Haiku **clamp** is handled for free: `applySessionMode` throws if `auto`
  isn't in `availableModes`, so the selector simply won't offer it.
- `Config` default stays non-auto; a user may set their own default to `auto`.

## Remaining risks (verify, not design)

1. **Latency** of the per-call RPC — now includes Write/Edit, higher frequency
   than the original Bash-only framing. Measure in the spike; it gates nothing
   architectural, only whether (b) is fast enough as-is.
2. **Reentrancy** — the hook (a grandchild of nvim) blocks synchronously on
   `--remote-expr` back into that same nvim. Safe *because* nvim sits idle in its
   async event loop awaiting the SDK's next message during a turn. Confirm
   `decide` never runs during a redraw/blocking moment.
3. **Settings-file hygiene** — merge safety, JSON validation, symlink/read-only.

## Phasing

- **Phase 1 (spike):** `decide` refactor + `session_id → SessionManager` lookup;
  hook script (self-scoping + fail-open); write-once merge-safe
  `settings.local.json`; `AGENTIC_SOCK` at spawn; `<localLeader>` keymap move.
  Manual e2e via `/tmp/agentic_acp_test/driver.py` (auto mode + real hook):
  assert deny-floor blocks, allow short-circuits (0 `request_permission`), and
  undecided reaches the classifier.
- **Phase 2 (productionise):** config flag to enable, gitignore handling,
  failure-mode coverage, multi-nvim same-cwd check.
- **Phase 3 (measure):** RPC latency (risk 1); only revisit transport if
  unacceptable.

## Testing

- **Unit:** `decide` verdict → `permissionDecision` mapping. Parity is structural
  (one function, two callers) rather than a separate assertion.
- **E2e:** the driver-harness assertions in Phase 1.
