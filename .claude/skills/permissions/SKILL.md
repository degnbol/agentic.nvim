---
name: permissions
description:
  Permission flow and client-side auto-approval — read-only tools, parse-tree
  shell command matching, allow/reject-always cache, /grant path scopes. Use
  when editing PermissionManager, PermissionRules, GrantSafety, GitFiles,
  PermissionFloat, the permission keymaps, or anything in the
  request-permission code path. Per-function rationale lives in docstrings on
  those modules — read them first; this skill is the cross-file overview, the
  four-mechanism rationale, and the safety-property index for /grant.
---

# Permissions

The permission system decides which agent tool calls run without a prompt.
The agent picks the commands; the user only answers prompts.

## Two-step system

The ACP provider's SDK runs its own permission check first — settings.json
allow/deny/ask, the claude provider's `allowed_tools` (`--allowedTools`),
working-directory membership, path safety. Only if that
returns `ask` does the SDK call `canUseTool`, which the bridge translates
into `session/request_permission` over ACP. The plugin is **strictly
downstream**: we can't override what the SDK silently approves or denies,
only decide how to handle what it escalates as `ask`. Every layer below
reduces prompt fatigue inside that escalation surface; the one exception
that *grants* new authorisation is `/grant`, which compensates with
git-recoverability gates.

So our `deny` is a backstop on the escalation surface only: a command the SDK
auto-approves never reaches us. An unconditional block needs a settings.json
`deny` rule. ACP has no method to read or write persistent SDK rules, so the
user edits `~/.claude/settings.json` for those.

State is per-session: it clears when the session ends or a saved session
loads, and survives a stop, a respawn and a provider switch.

## Permission flow

```
Provider sends "session/request_permission"
  -> PermissionManager.add_request(request, callback)
     -> _try_auto_approve -> decide() runs the checks below
        -> approved/rejected: callback fires immediately, skip UI
        -> otherwise: fall through to interactive prompt
     -> Queue request (sequential — one prompt at a time)
     -> PermissionFloat.open renders prompt anchored to the chat window
     -> Bind buffer-local option keys on all widget buffers
  -> User presses permission key (PermissionManager:_complete_request)
     -> Cache an allow/reject-always decision
     -> Close float
     -> Send result back to provider via callback
     -> Dequeue next
```

## Four auto-approval mechanisms

The check order is in the `PermissionManager:decide` docstring; the first
decision wins.

### 1. Approved kinds (`Config.permissions.auto_approve_kinds`)

Listed kinds (default `read`, `search`, `skill`) approve whatever the path,
with the kind as decider. Bypasses the provider's directory sandbox, which
otherwise prompts for paths outside `additionalDirectories` even for reads.

### 2. Shell command parsing (always on)

Each `Bash`/`execute` command is parsed with the **zsh treesitter grammar**
(commands execute in zsh — see the `claude` skill's `references/execute-tool.md`
§ Shell) and every leaf classified independently, so pipelines, loops,
conditionals, redirects, and env-prefixes are all checked structurally.
`auto_approve_tier = nil`
approves no shell command; deny/ask still apply.

**Two matcher layers run per leaf.** The **glob matcher** consumes Claude's
`Bash(...)` `allow`/`deny`/`ask` patterns from the global and project
settings.json (`PermissionRules.get_settings_patterns`). The **structured
matcher** (`lua/agentic/utils/permission_structured.lua`) consumes the bundled
`lua/agentic/permissions.json` plus any `Config.permissions.structured`
additions: cmd-keyed gate arrays (`read_only`, `safe_write`, `ask`, `deny`)
matched on flag identifiers and positionals. It exists because globs are
unsound against option clustering and GNU abbreviation (`sort -uo out`,
`sort --out=x`).

**Classify by un-redirected effect.** A command that only prints to stdout is
`read_only` (writing via pipe/redirect is caught structurally by the walker);
one that mutates disk or executes arbitrary code as its normal action is
`safe_write`, with write-causing options/subcommands carved out as `ask`/`deny`.

**Guarantees the walker enforces** (mechanics in
[references/parsing.md](references/parsing.md)):

- **Fail-closed parse** — a tree that may not match what zsh runs prompts
  (§ Pipeline).
- **A static token is the delivered word** — quote removal applied
  (§ Arg token text).
- **Reject-by-default walk** — loops, conditionals and substitutions recurse;
  each inner command must approve on its own (§ Pipeline).
- **No call to an unsafe function**, in any scope or order (§ Pipeline).
- **Redirects classified structurally** — `> /dev/null` and `2>&1` are safe,
  any other file redirect bails, whether or not the command succeeds.
- **One name predicate for every binding** — `ShellParse.is_safe_var_name`.
- **Dynamic tokens wildcard deny/ask, never allow** (§ Token expansion).
- **Over-approximation is sound for deny/ask**; allow holds in every parse
  (§ Over-approximation).

**Composition per leaf:**
`approve iff (glob_allow OR structured_allow) AND NOT (glob_deny OR
structured_deny OR glob_ask OR structured_ask)`. The allow set resolves per
`Config.permissions.auto_approve_tier`, the highest kind that counts
(`"safe_write"` = `read_only` ∪ `safe_write`, `"read_only"` = `read_only`
only, `nil` = none). A settings.json `allow` counts at either non-nil level;
session allow-always leaves count at every level.

Deny additionally **short-circuits to a rejection**:
`PermissionRules.should_auto_reject` runs before `evaluate` and rejects the
whole command with no prompt when any executed leaf matches a concrete deny
gate. Ask only withholds approval.

#### Known limitations (uncatchable — fall through to a prompt)

A write/exec intent hidden inside an opaque token cannot be classified by
token-level matching. The failure mode is auto-approving a write at any
non-nil `auto_approve_tier`, never bypassing a `deny`/`ask` that *did* match:

- **`sed`** `e`/`w` commands and `s///e`/`s///w` flags — the script body is
  opaque and a glob carve-out is unsound. Only `-i` asks.
- **`awk`** script body (`-f scriptfile` or inline) — opaque. The `deny` on
  positional `*system*` is the backstop.
- **`mlr`** write verbs past a `then` chain or inside a `put`/`filter` DSL —
  positional matching sees only the first verb.
- A user *glob* deny in settings.json gets no dynamic-token wildcard, so a
  `$var` can launder past it — express the gate structurally to close it.

### 3. Allow/reject-always cache

ACP leaves persistence of `allow_always`/`reject_always` to the provider, and
providers vary. The plugin caches every `*_always` decision in
`PermissionManager._always_cache`, keyed per resource, not per kind (see
`_build_cache_key`). A cache hit sends `allow_once`/`reject_once`.

**Execute `allow_always` remembers leaves, not the whole string.** It harvests
the safe-but-unruled leaves (`tally_unapproved`) into `_execute_leaf_allow`, so
a later block sharing them auto-approves. Deny/ask-gated or structural parts
are not rememberable, so the whole-command entry is kept as a fallback.
`reject_always` stays whole-command.

### 4. Grant scopes (`/grant`)

A per-session **set** of path scopes (`PermissionManager._grant_scopes`):
`/grant X` adds, `/grant off` clears, the picker toggles.
`Config.permissions.default_grant` (`/tmp`, `$TMPDIR`, `.`, `root`; `{}` for none) is added silently at
session start (`SessionManager:_apply_default_grants`). Every scope is a path
or glob compiled by `GrantSafety.compile_scope`; the keywords `.` and `root`
resolve against the session's ACP cwd in `SessionManager:_resolve_grant_input`.

Two mutation producers feed one policy: ACP file tool calls (`_check_grant`)
and Bash effects — redirect writes and plain `rm` operands that
`PermissionRules.evaluate` pins to literal paths (`_bash_effects_clear`).
Bash effects clear only for absolute paths: the Bash tool's cwd persists
across calls and moves with an in-command `cd`.

**Membership is necessary but not sufficient** — safety properties on top:

1. **Full resolution.** Both the literal and the resolved path must be granted
   (`GrantSafety.resolve`, `_granted_pair`).
2. **Hidden exclusion.** A `.`-segment below a scope root is out unless the
   pattern names it (`GrantSafety.scope_contains`).
3. **Recoverability** — `GrantSafety.safe_for_kind`. A Bash delete of
   scratch clears only for a path redirected to earlier in the same command
   (`tmp_cleanup`).
4. **Verified Claude-owned range.** `SessionManager:_try_record_edit_range`
   records an Edit's line range before it applies, `finalize_edit_range`
   promotes it on `completed`, and `GrantSafety.verify_edit_range` drops it
   once the on-disk lines diverge.
5. **TOCTOU revalidation.** Re-stat just before approving; bail on any change.
6. **Cache precedence.** A cached `reject_always` wins over a would-be-safe
   grant check — both grant paths run *after* the cache.
7. **Wide-scope WARN** — `GrantSafety.is_wide_scope`.

## Permission response keys

Bound buffer-locally on all widget buffers (`Config.keymaps.permission`).
`Lx` (reject all) sends `reject_once` for the current request and `cancelled`
for the rest, so the provider can adapt on the next turn; `<C-c>`
(`keymaps.widget.stop_generation`) kills the turn via `session/cancel`.

**`optionId` is opaque.** `request.options[].optionId` (`"reject-once"`) is not
`option.kind` (`"reject_once"`). Look the option up by `optionId` and read its
`kind`.

## Permission float

`PermissionFloat` — one instance per session, paired with its
`PermissionManager`, in a separate buffer so chat updates never displace the
prompt. Never focusable: the keys live on the session's buffers and the
anchor's `companion_bufs`. `PermissionManager:refresh_float` re-places it on
layout events.
