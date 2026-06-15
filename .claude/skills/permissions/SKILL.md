---
name: permissions
description:
  Permission flow and client-side auto-approval — read-only tools, compound
  Bash matching, allow/reject-always cache, /trust scope. Use when editing
  PermissionManager, PermissionRules, TrustSafety, GitFiles, PermissionFloat,
  the permission keymaps, or anything in the request-permission code path.
  Per-function rationale lives in docstrings on those modules — read them
  first; this skill is the cross-file overview, the four-mechanism rationale,
  and the safety-property index for /trust.
---

# Permissions

## Two-tier system (we are tier 2)

The ACP provider's SDK runs its own permission check first — settings.json
allow/deny/ask, working-directory membership, path safety. Only if that
returns `ask` does the SDK call `canUseTool`, which the bridge translates
into `session/request_permission` over ACP. The plugin is **strictly
downstream**: we can't override what the SDK silently approves or denies,
only decide how to handle what it escalates as `ask`. Every layer below
reduces prompt fatigue inside that escalation surface; the one exception
that *grants* new authorisation is `/trust`, which compensates with
git-recoverability gates.

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
approve or reject; first decision wins. Each layer has its own
`Config.auto_approve_*` master switch (all default `true`).

### 1. Read-only tools (`Config.auto_approve_read_only_tools`)

ACP kinds `"read"` and `"search"` (Read, Grep, Glob) approve unconditionally.
Bypasses the provider's directory sandbox, which otherwise prompts for paths
outside `additionalDirectories` even for reads.

Fallback for the kind check: if `request.toolCall.kind` does not match,
but the tracker entry from the prior `tool_call` notification has a
read-only kind, approve anyway. This catches opencode raising
`external_directory` (kind="other") under the same `toolCallId` as the
underlying read tool. See the acp skill's `references/opencode.md`
§ "Permission request shape" finding 1.

### 2. Compound Bash commands (`Config.auto_approve_compound_commands`)

Fills a provider gap: the SDK matches the whole command string against each
`Bash(...)` pattern, so `grep foo | head -20` prompts even when both
`Bash(grep *)` and `Bash(head *)` are allowed. `PermissionRules`
(`lua/agentic/utils/permission_rules.lua`) walks the zsh parse tree and
matches each leaf separately.

Two layers run per leaf. The **glob matcher** consumes Claude's `Bash(...)`
patterns from `~/.claude/settings.json`, `.claude/settings.json`, and
`Config.permissions.{read_only, safe_write, deny, ask}` — shared schema
with the Claude TUI, kept for user-side rules. The **structured matcher**
(`lua/agentic/utils/permission_structured.lua`) consumes the bundled
`lua/agentic/permissions.json`, which is now purely structured (no globs),
plus any `Config.permissions.structured` user additions. It is a cmd-keyed
table: each command maps to up to four gate-kind arrays (`read_only`,
`safe_write`, `ask`, `deny`), and each gate matches on literal flag
identifiers (`options`) and ordered positional patterns (`positionals`).
The kind name encodes the policy — `read_only` approves at
"read-only"/"allow", `safe_write` only at "allow", `ask`/`deny` are
unconditional. Classify a command by its *un-redirected* effect: a command
that only prints to stdout is `read_only` (writing via pipe/redirect is
caught structurally by the walker), while one that mutates disk or executes
arbitrary code as its normal action is `safe_write` — carve out the
write-causing options/subcommands as `ask`/`deny`. Users add or override via
`Config.permissions.structured`
(deep-merged "force" over the bundled defaults; a cmd key replaces that
command's bundled kind-arrays wholesale, `vim.NIL` disables it). The structured layer exists because globs are
unsound against option clustering and GNU abbreviation — `sort -uo out`,
`sort --out=x`, and `sort -oFILE` all evade a `Bash(sort * -o *)` glob.
The matcher over-approximates option presence per token (single-dash
`-uo` expands to letters `{u, o}` AND long-name `uo`; double-dash
`--output=x` becomes prefix-matched long-name `output`), which is sound
for deny/ask — extra candidates can only widen a match, never miss one.

Pipeline summary (read the module's docstrings for full detail):

1. **Parse** with the zsh treesitter grammar. Fail-closed: no parser, parse
   failure, or any error node → prompt. The zsh parser is a hard dependency.
2. **Walk** reject-by-default. Bail on dynamic command names, code-taking
   builtins (`eval`/`source`/`.`), `if`, and `case`. Anonymous separators
   (`|`, `&&`, `;`, `&`, newline) and comments are skipped. Loops
   (`for`, `while`, `until`) recurse: a `for` list must be literal or glob
   (substitution in the list bails), and every body command must itself
   approve. Command/process substitution bails in argument, command-name,
   for-list, and redirect-target positions — those launder dangerous
   tokens past deny/ask (`find $(echo '-exec rm')`). It is allowed only
   as a `variable_assignment` value or array element, where its inner
   commands recurse through the same walker (so `f=$(rm x)` still bails
   because `rm` is not allowed).
3. **Classify** redirects and env-prefixes structurally. `> /dev/null` and
   FD duplication (`2>&1`) are safe; any other file redirect bails. Env
   prefixes that hijack execution (`PATH=`, `LD_*`, `BASH_ENV`) bail.
4. **Extract** each safe leaf — the command name and quote-stripped arg
   tokens, minus redirects and env-prefixes. The leaf goes to the glob
   matcher as a joined string; the tokenised form (`{cmd_name, args}`)
   goes to the structured matcher. `stdbuf` wrappers and system
   binary-dir prefixes are stripped on the command name.
5. **Check** against compiled patterns and structured entries, sourced
   per layer:
   - Bundled `lua/agentic/permissions.json` (when
     `Config.permissions.use_plugin_defaults`) — structured entries only.
   - `~/.claude/settings.json` and `.claude/settings.json` (when
     `Config.permissions.use_claude_settings`) — glob patterns.
     Mtime-cached.
   - `Config.permissions.{read_only, safe_write, deny, ask}` — glob
     patterns. `Config.permissions.structured` — structured entries.
     Recompiled on table-reference change.
6. **Resolve** the allow list per `Config.permissions.auto_approve`. Both
   layers honour the same toggle: `"allow"` accepts entries in
   `read_only` ∪ `safe_write` (mkdir, touch, git add, …); `"read-only"`
   accepts `read_only` only; `nil` accepts no allow rules (compound path
   will not approve; deny/ask still apply).
7. **Compose** per leaf:
   `approve iff (glob_allow OR structured_allow) AND NOT (glob_deny OR
   structured_deny OR glob_ask OR structured_ask)`. Deny/ask are OR across
   layers; allow is union. A leaf approves only when every layer that
   votes against it stays silent.

Command-source fallback: if `request.toolCall.rawInput.command` is nil
and the tracker kind is `"execute"`, read from `tracker.argument` instead
(opencode quirk — see acp skill `references/opencode.md` finding 3).

#### Known limitations (uncatchable — fall through to a prompt)

A command whose write/exec intent is hidden inside an opaque token cannot
be classified by token-level matching. These are accepted residuals, not
bugs — the failure mode is auto-approving a write at `auto_approve` =
`"read-only"`, never bypassing a `deny`/`ask` that *did* match:

- **`sed`** `e`/`s///e` (exec) and `w`/`W`/`s///w` (write) — the script
  body is opaque (no sed parser/injection). A glob carve-out in the
  positional is unsound (GNU sed needs no space after `e`, accepts a bare
  `e` or an address prefix, `s///e` allows any delimiter/flag order). Kept
  in `read_only` with a `deny` on `-i` only.
- **`awk`** script body via `-f scriptfile` or DSL — opaque. The
  `awk` `deny` on positional `*system*` is a parser-independent backstop
  (catches an inline `system(...)` in the script positional).
- **`mlr`** write verbs reached past a `then` chain (`mlr cat then tee x`)
  or inside a `put`/`filter` DSL string — positional matching is
  index-based and sees only the first verb, and the DSL body is one opaque
  positional. The `ask` on `split`/`tee` and `deny` on `-I` catch only the
  direct forms.
- **Dynamic expansion** (`sort $FLAG out` where `$FLAG=-o`) — tolerated for
  any `$var`/glob/`~`; the token is not a literal flag.

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

### 4. Trust scope (`/trust`, `Config.auto_approve_trust_scope`)

Per-session scope for file-scoped tool kinds (edit, write, create, delete,
move). User picks a scope via `/trust`:

| Argument | Meaning |
|---|---|
| `repo` | Any git-tracked file in the current repo |
| `here` | Tracked files under the activation cwd |
| `off` | Clear |
| any other | Literal path or `vim.glob.to_lpeg` glob |

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
