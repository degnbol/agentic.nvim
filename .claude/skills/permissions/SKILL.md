---
name: permissions
description:
  Permission flow and client-side auto-approval — read-only tools, parse-tree
  shell command matching, allow/reject-always cache, /trust scope. Use when editing
  PermissionManager, PermissionRules, TrustSafety, GitFiles, PermissionFloat,
  the permission keymaps, or anything in the request-permission code path.
  Per-function rationale lives in docstrings on those modules — read them
  first; this skill is the cross-file overview, the four-mechanism rationale,
  and the safety-property index for /trust.
---

# Permissions

## Two-step system

The ACP provider's SDK runs its own permission check first — settings.json
allow/deny/ask, working-directory membership, path safety. Only if that
returns `ask` does the SDK call `canUseTool`, which the bridge translates
into `session/request_permission` over ACP. The plugin is **strictly
downstream**: we can't override what the SDK silently approves or denies,
only decide how to handle what it escalates as `ask`. Every layer below
reduces prompt fatigue inside that escalation surface; the one exception
that *grants* new authorisation is `/trust`, which compensates with
git-recoverability gates.

This bounds our `deny` too: a bundled/structured `deny` only fires on the SDK's
`ask` escalation surface. A command the SDK auto-approves (e.g. the user
allow-lists `Bash(find:*)` in settings.json) never reaches us, so our deny can't
block it. For an *unconditional* block the user must also add a settings.json
`deny` rule (SDK-enforced, tier 1). Our deny is a backstop on the escalation
surface, not a hard guarantee.

State is per-session. Everything below clears on `/new`, session cancel,
or tabpage close.

## Permission flow

```
Provider sends "session/request_permission"
  -> PermissionManager.add_request(request, callback)
     -> _try_auto_approve() runs the four checks below
        -> approved/rejected: callback fires immediately, skip UI
        -> otherwise: fall through to interactive prompt
     -> Queue request (sequential — one prompt at a time)
     -> PermissionFloat.open renders prompt anchored to the chat window
     -> Bind buffer-local keymaps 1..N on all widget buffers
  -> User optionally opens diff preview in a new tabpage
  -> User presses permission key
     -> Send result back to provider via callback
     -> Close float, clear diff preview, dequeue next
```

## Four auto-approval mechanisms

All in `PermissionManager._try_auto_approve()`. Independent — any one can
approve or reject; first decision wins. Read-only tools, skills, and trust
scope each have a `Config.auto_approve_*` master switch (all default `true`);
shell command parsing always runs (no switch — see mechanism 2).

### 1. Read-only tools (`Config.auto_approve_read_only_tools`)

ACP kinds `"read"` and `"search"` (Read, Grep, Glob) approve unconditionally.
Bypasses the provider's directory sandbox, which otherwise prompts for paths
outside `additionalDirectories` even for reads.

Fallback for the kind check: if `request.toolCall.kind` does not match,
but the tracker entry from the prior `tool_call` notification has a
read-only kind, approve anyway. This catches opencode raising
`external_directory` (kind="other") under the same `toolCallId` as the
underlying read tool.

### 2. Shell command parsing (always on)

Each `Bash`/`execute` command is parsed with the **zsh treesitter grammar**
(commands execute in zsh — see the `claude` skill's `references/execute-tool.md`
§ Shell) and every leaf classified independently, so pipelines, loops, conditionals,
redirects, and env-prefixes are all checked structurally — catching evasions a
whole-string glob cannot see. This runs unconditionally with no master switch:
the parser only ever turns the provider's SDK `ask` escalations into approvals
for provably-safe commands or rejections for provably-dangerous ones — both
strictly better than the prompt you'd get otherwise, with no safety downside
(the SDK runs its own check underneath). "Confirm every shell command" is
achieved by leaving the allow rules empty. This fills a provider gap: the SDK
matches the
entire command string against each `Bash(...)` pattern, so `grep foo | head -20`
prompts even when both `Bash(grep *)` and `Bash(head *)` are allowed.
`PermissionRules` (`lua/agentic/utils/permission_rules.lua`) walks the parse
tree and matches each leaf separately.

**Two matcher layers run per leaf.** The **glob matcher** consumes Claude's
`Bash(...)` patterns from `~/.claude/settings.json`, `.claude/settings.json`,
and `Config.permissions.{read_only, safe_write, deny, ask}` — shared schema
with the Claude TUI, kept for user-side rules. The **structured matcher**
(`lua/agentic/utils/permission_structured.lua`) consumes the bundled
`lua/agentic/permissions.json` (purely structured, no globs) plus any
`Config.permissions.structured` additions. It is cmd-keyed: each command maps
to up to four gate-kind arrays (`read_only`, `safe_write`, `ask`, `deny`),
matched on literal flag identifiers (`options`) and ordered positional patterns
(`positionals`). It exists because globs are unsound against option clustering
and GNU abbreviation — `sort -uo out`, `sort --out=x`, and `sort -oFILE` all
evade a `Bash(sort * -o *)` glob.

**Safety, not call-correctness.** The matcher classifies a command by its
*intended structural effect* — never by whether the invocation is well-formed
or would succeed. It carries no per-command getopt/signature table: guarding
safety does not require knowing a command's valid call signature, and a
malformed command that fails at runtime fails safely — its redirects and
env-prefixes are still classified structurally (below), separately from the
command itself. Modelling call signatures would be scope creep that buys no
safety. (`value_options` on the allow path is a fail-safe convenience to cut
over-prompts — an unlisted flag over-prompts, never under-guards — not a
correctness model.)

**Classify by un-redirected effect.** A command that only prints to stdout is
`read_only` (writing via pipe/redirect is caught structurally by the walker);
one that mutates disk or executes arbitrary code as its normal action is
`safe_write`, with write-causing options/subcommands carved out as `ask`/`deny`.
The kind name encodes the policy — `read_only` approves at "read-only"/"allow",
`safe_write` only at "allow", `ask` and `deny` are both unconditional but differ
in outcome: **`ask` withholds approval and prompts; `deny` rejects immediately
(no prompt, the command never runs)**. Users override via
`Config.permissions.structured` (deep-merged over the bundled defaults; a cmd
key replaces that command's bundled kind-arrays wholesale, `vim.NIL` disables
it).

**Guarantees the walker enforces** (token-level mechanics — absorption parses,
`leading_options`, the over-approximation soundness argument, the full pipeline
— are in [references/parsing.md](references/parsing.md)):

- **Fail-closed parse.** No parser, parse failure, or any error node → prompt.
  The zsh parser is a hard dependency.
- **Reject-by-default walk.** Bails on dynamic command names and code-taking
  builtins (`eval`/`source`/`.`). Loops and `if`/`case` recurse into every
  branch — each body command must itself approve. A bare `command_substitution`
  in argument, for-list, or assignment-value position recurses: its inner must
  approve standalone, and its output is spliced as a dynamic token so a gated
  outer command still prompts. A quoted string in argument position whose only
  expansions are command substitutions (`"count: $(ls)"`) recurses each inner
  and splices the whole quoted arg as one dynamic token. Process substitution
  `<(…)`/`>(…)` in argument
  position likewise recurses its inner, splicing a static `/dev/fd` placeholder.
  Substitution as the command name, unquoted concatenation (`a$(b)c`), a quoted
  string mixing `$var`/arithmetic with text (`"x$y$(ls)"`), process
  substitution outside argument position, case value/pattern, or redirect target
  still bails (see [references/parsing.md](references/parsing.md)).
- **Redirects and env-prefixes classified structurally.** `> /dev/null` and FD
  duplication (`2>&1`) are safe; any other file redirect bails. Execution-hijack
  env prefixes (`PATH=`, `LD_*`, `BASH_ENV`) bail. This runs regardless of
  whether the command would succeed — a failing command's redirect has already
  truncated its target, which is *why* redirects are guarded here and not by the
  command's classification.
- **Dynamic tokens wildcard deny/ask, never allow.** A runtime-expanding token
  (`$var`, unquoted glob; `~` exempt) satisfies any deny/ask `options` or
  positional requirement at or after its index, so laundering a payload through
  `$f` at a gated command prompts. For allow it stays concrete, so it never
  widens an approval. Arithmetic `$((…))` is the one expansion classified
  *static* — argument position, provably-zsh exec shell only (see
  [references/parsing.md](references/parsing.md) § "Arithmetic (zsh-gated)").
- **Over-approximation is sound for deny/ask.** Option presence is
  over-approximated per token — extra candidates can only widen a deny/ask
  match, never miss one. Allow uses a single parse, so an unknown subcommand
  still prompts.

**Composition per leaf:**
`approve iff (glob_allow OR structured_allow) AND NOT (glob_deny OR
structured_deny OR glob_ask OR structured_ask)`. Deny/ask are OR across layers;
allow is union; the allow set resolves per `Config.permissions.auto_approve`
(`"allow"` = `read_only` ∪ `safe_write`, `"read-only"` = `read_only` only,
`nil` = no allow rules). A leaf approves only when every layer that votes
against it stays silent.

Deny additionally **short-circuits to a rejection**: a separate existential pass
(`PermissionRules.should_auto_reject`, run by the manager *before*
`should_auto_approve`) rejects the whole command — no prompt — as soon as any one
executed leaf matches a concrete deny gate. Ask only *withholds approval* (the
command still prompts). The deny pass is **concrete-only**: a dynamic token
(`$var`, glob) does NOT satisfy a deny gate there, so `rm $flags x` falls through
to the approve walk and prompts, while `rm -f x` rejects. A parse failure returns
false (prompt, not reject) — unparseable commands fail closed to a prompt, never
a silent reject.

#### Known limitations (uncatchable — fall through to a prompt)

A command whose write/exec intent is hidden inside an opaque token cannot
be classified by token-level matching. These are accepted residuals, not
bugs — the failure mode is auto-approving a write at `auto_approve` =
`"read-only"`, never bypassing a `deny`/`ask` that *did* match:

- **`sed`** `e`/`s///e` (exec) and `w`/`W`/`s///w` (write) — the script
  body is opaque (no sed parser/injection). A glob carve-out in the
  positional is unsound (GNU sed needs no space after `e`, accepts a bare
  `e` or an address prefix, `s///e` allows any delimiter/flag order). Kept
  in `read_only` with an `ask` on `-i` only (in-place edit is a legitimate
  mutation the user may want — prompt, don't reject).
- **`awk`** script body via `-f scriptfile` or DSL — opaque. The
  `awk` `deny` on positional `*system*` is a parser-independent backstop
  (catches an inline `system(...)` in the script positional).
- **`mlr`** write verbs reached past a `then` chain (`mlr cat then tee x`)
  or inside a `put`/`filter` DSL string — positional matching is
  index-based and sees only the first verb, and the DSL body is one opaque
  positional. The `ask` on `split`/`tee` and `-I` catches only the direct
  forms.
- **Dynamic expansion** at a gated command prompts rather than launders
  (a dynamic token wildcards deny/ask — see above), so `find . $f` and
  `f=$(…); find . $f` escalate. The exception: a `$var` resolving to a literal
  bound earlier in the same straight-line sequence is matched as that literal —
  bare or single-word quoted (`f=/safe; find $f` and `find "$f"` approve,
  `f=--exec; find $f` denies). An **unquoted** concatenation `$d/x` also splices
  as one token: static when every part is a safe literal or bound var
  (`base=/safe; head $base/x` approves; `base=-o; sort $base/x` resolves to
  `-o/x`, which hits sort's write gate), else dynamic (`head $d/SKILL.md`
  approves at a read-only command; `find . $d/x` prompts). A **quoted**
  concatenation `"$f/x"` is not statically resolved — it stays a dynamic token
  (approves at a read-only command, prompts at a gated one).
  A quoted command substitution `"$(cmd)"` is walked and spliced as a dynamic
  token like the bare `$(cmd)` — `cat "$(ls)"` approves, `find "$(echo
  -exec rm)"` still prompts (mechanism in
  [references/parsing.md](references/parsing.md)). An intervening control-flow
  sibling keeps the binding unless it actually rebinds the name
  (`f=/safe; if c; then :; fi; find $f` approves; `…; then f=/danger; fi; …`
  prompts). A multi-word / glob / substitution value, or a binding rebound by an
  un-enumerable construct, stays dynamic and prompts.
- A user *glob* deny in settings.json cannot get the dynamic-token wildcard
  treatment (only the typed structured gates can), so it keeps the pre-existing
  hole — express the gate structurally to close it.

Sub-language injection (awk/jq/sql/python parsed *into* command-argument
strings via `queries/zsh/injections.scm`) is **best-effort enrichment, never
the sole guard** — it depends on the injection query being on the
runtimepath, which a downstream consumer can remove. The parser-independent
backstops (the `awk *system*` deny) stay regardless of injection descent.

### 3. Allow/reject-always cache

ACP leaves persistence of `allow_always`/`reject_always` as
provider-specific behaviour, and providers vary. The plugin caches every
`*_always` decision in `PermissionManager._always_cache` and short-circuits
subsequent matches.

**Cache keys are per-resource, not per-kind** — see
`_build_cache_key`'s docstring for the two-path strategy. Known kinds use
`CACHE_KEY_FIELDS` (file_path / command / url / query / …). Unknown kinds
fall back to a hybrid path: the whole `rawInput` minus
`CACHE_NOISE_FIELDS` (`description`, `timeout`), with top-level keys
sorted for stable identity. When no identifying input is available the
key is `nil` and the next call re-prompts — safer-but-pessimistic, the
explicit design trade.

Matched cache entries always send `allow_once` / `reject_once` back to
the provider (mirrors the other auto-approval checks).

**Execute `allow_always` remembers leaves, not the whole string.** On an
execute prompt it harvests the individual safe-but-unruled leaves
(`tally_unapproved`) into `_execute_leaf_allow`, injected as session allow
patterns so a later block sharing them auto-approves. Deny/ask-gated or
structural parts aren't rememberable (`complete = false`), so the
whole-command `_always_cache` entry is also kept as a fallback. `reject_always`
stays whole-command.

### 4. Trust scope (`/trust`, `Config.auto_approve_trust_scope`)

Per-session scope for file-scoped tool kinds (edit, write, create, delete,
move). The user picks a scope via `/trust`; the `tmp` scope is also activated
automatically at session start when `Config.permissions.trust_tmp` is on
(default), so scratch operations work out of the box. `SessionManager:_apply_default_trust`
(called from `new_session` and `load_acp_session`) sets it silently — no chat
message, headers still update — and never overrides a scope the user set this
session.

| Argument | Meaning |
|---|---|
| `repo` | Any git-tracked file in the current repo |
| `here` | Tracked files under the activation cwd |
| `tmp` | Scratch files strictly under a tmp root (`/tmp`, `$TMPDIR`) |
| `off` | Clear |
| any other | Literal path or `vim.glob.to_lpeg` glob |

The `tmp` scope is git-agnostic — recoverability is "ephemeral by convention",
not git, so clobbering scratch is not loss of work (`TrustSafety.build_tmp_scope`,
`is_under_tmp`; `safe_for_kind` short-circuits write/create on `args.tmp`). It is
also the first scope to gate a **second mutation producer**: alongside ACP file
edits, Bash redirect writes now feed the same policy oracle.
`PermissionRules.evaluate` extracts them as `write` effects — see its docstring
and `PermissionManager._bash_effects_clear` for the extraction and per-effect
tmp check. Under `Config.permissions.tmp_cleanup` (default on), deletes are also
cleared, correlated to a write/create earlier in the **same** command
(intra-command only — no cross-command ledger yet). The rm-delete fallback in
`walk_command` documents the per-command delete-emission mechanics.

**Scope membership is necessary but not sufficient** — the orchestrator
(`PermissionManager._check_trust`) layers six safety properties on top:

1. **Symlink resolution.** Both the original path AND its
   `vim.uv.fs_realpath` must lie inside scope. A tracked symlink pointing
   outside (`~/.ssh/authorized_keys`) is rejected.
2. **Per-kind recoverability** — see `TrustSafety.safe_for_kind` and the
   `safe_for_*` predicates in `lua/agentic/utils/trust_safety.lua`:
   - `create` — file does not exist
   - `write` — new file, OR tracked + clean
   - `delete` — tracked + clean
   - `edit` — new file, tracked + clean, pure addition (diff.old is a
     contiguous line subsequence of diff.new), edit range disjoint from
     unstaged hunks, OR every overlapping hunk is a verified Claude-owned
     range
   - `move` — source satisfies `edit`, destination satisfies `write`,
     both symlink endpoints in scope
3. **Verified Claude-owned range.** Ranges are *recorded at edit time,
   not re-discovered at check time*. At the initial `tool_call`
   notification (which fires *before* the SDK applies the edit — see acp
   skill § "Edits are not applied before permission"),
   `SessionManager:_try_record_edit_range` reads the file and finds
   `diff.old` as a unique line subsequence, then delegates to
   `PermissionManager:record_pending_edit` which stashes the start line in
   `_pending_edits`. On the matching `tool_call_update`
   with `status: "completed"`, `finalize_edit_range` promotes it to
   `_edit_records` with `end_line = start_line + #diff.new - 1` and the
   recorded `new_lines`. At trust-check time,
   `TrustSafety.verify_edit_range` confirms the on-disk content at the
   recorded range still equals `new_lines`. Any divergence drops the
   record.

   **Why range-based not content-search.** Claude's Edit tool is
   string-based — no line numbers in the payload — and the SDK's
   `FileEditOutput.structuredPatch` is not forwarded by claude-agent-acp
   (`rawOutput` is flattened to a success string). We synthesise ranges
   ourselves using the tool's `old_string` uniqueness contract. Searching
   for `diff.new` at check time would be ambiguous for short replacements
   like `}`, `end`, blank lines.
4. **TOCTOU revalidation.** Capture `mtime`/`size` (or non-existence)
   before the safety check, re-stat just before approving, bail on any
   change. Closes the same-process race between the git snapshot and
   `callback`.
5. **Cache precedence.** A cached `reject_always` (`_always_cache`) wins
   over a would-be-safe trust check — trust runs *after* the cache.
6. **Wide-scope WARN.** When the user supplies a path scope that covers
   `$HOME`, a top-level dir (`/`, `/tmp`, `/var`, …), or starts with an
   unanchored `**`, `Logger.notify` fires a WARN with the affected
   kinds (`TrustSafety.is_wide_scope`).

`git_files.lua` resolves the worktree's actual index path via
`git rev-parse --git-path index` (`.git/worktrees/<name>/index` for
worktree checkouts, plain `.git/index` otherwise) and uses that for
mtime-based cache invalidation of the tracked-files set.

Scope display string is also pushed into `vim.t[tab].agentic_headers` so
external UI plugins surface it via `AgenticHeadersChanged`.

## Permission response keys

Bound buffer-locally on all widget buffers (chat, input, todos, code,
files, diagnostics). Numbers match escalating severity:

| Key | Action | ACP outcome |
| --- | --- | --- |
| `1` | Allow once | `selected` + `allow_once` |
| `2` | Allow always | `selected` + `allow_always` |
| `3` | Reject once (show next) | `selected` + `reject_once` |
| `4` | Reject all | `reject_once` current + `cancelled` remaining |
| `5` | Reject always | `selected` + `reject_always` |
| `<C-c>` | Hard abort | `cancelled` for all + `session/cancel` |

Numbers adapt if the provider sends fewer options.

**`4` vs `<C-c>`.** Both stop permission processing. `4` sends
`reject_once` for the current call, so the provider sees an active
rejection and can adapt (explain, suggest alternatives) on the next turn.
`<C-c>` kills the turn immediately via `session/cancel` — provider gets
no chance to react. Use `4` when you want to reject *and* steer.

**`optionId` is opaque.** `request.options[].optionId` is a
provider-assigned string (`"reject-once"`); it is NOT the same as
`option.kind` (`"reject_once"`). Map by looking up the option by
`optionId` in the original options array and reading its `kind`. Do not
compare `optionId` against kind strings.

## Permission float positioning

Owned by `PermissionFloat` (`lua/agentic/ui/permission_float.lua`) — one
instance per tab, paired with the tab's `PermissionManager`. Separate
buffer from the chat, so chat updates never displace the prompt.

- **Anchor.** `relative = "win"` against the chat window of the owning
  tab, resolved from `message_writer.bufnr` via `vim.fn.win_findbuf`
  filtered by tab id. Corner and offsets come from
  `Config.permission_float` (default `NE`). `WinResized` reapplies
  geometry; a `WinClosed` autocmd on the chat winid closes the float if
  the chat window goes away.
- **Focus.** `focusable = false` blocks `<C-w>w`, mouse, and
  programmatic focus. The float never holds the cursor. The number-key
  bindings live on the widget buffers (not the float buffer), so the
  user must have focus on one of those to answer.
- **Hidden chat edge case.** If `_find_chat_winid` returns nil
  (widget toggled away), the open call is a no-op. `_process_next`
  records `current_request` but `_setup_keymaps` short-circuits on nil
  mapping — the prompt cannot be answered until the widget reopens, and
  the float does not auto-render on reopen. Niche — supported flow is
  to keep the chat visible while a prompt is pending.

## Known ACP limitation

There is no ACP method for managing persistent permission rules. The
TUI's `/permissions` has no protocol equivalent — clients can only
respond to per-call escalations, not query or write SDK rules. That's
*why* the four mechanisms above exist; for persistent rules the user
edits `~/.claude/settings.json` directly. The plugin also exposes a
`/trust` scope and `Config.permissions.*` lists as project-local
extensions of the same idea.
