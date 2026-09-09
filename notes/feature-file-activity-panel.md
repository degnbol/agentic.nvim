# Plan: file activity panel

## Problem

Nothing tracks which files the agent has touched over a session. In a
long session — or one the user looked away from and came back to — the
only record is the chat buffer, which interleaves edits with prose, tool
output and subagent activity, and has no per-file view at all.

The want is an overview: *what has been modified, in total, in this
session*. Not a feed (the chat buffer is already the feed), and not
always on screen — a toggled panel.

## Scope

**v1** — files created or edited by the edit-family tool calls, one row
per path, each row marked created or edited.

**Deferred, but the data model must not preclude them:**

- files *read* (`kind == "read"`) as a second, filterable op class
- line ranges per file
- files changed by `Execute` (Bash), which also brings **deletions** —
  see § Delete

**Explicitly out of scope:** attributing files to `Grep`/`Glob`
(`kind == "search"`). See § Why search is excluded.

## Prerequisite: an adapter fix this feature depends on

`ClaudeAgentACPAdapter:__handle_tool_call_update`
(`lua/agentic/acp/adapters/claude_agent_acp_adapter.lua:262-268`) drops
every update that has neither `status` nor `rawInput`. One legitimate
update matches that shape and is being discarded.

The bridge registers a PostToolUse hook callback for `Edit` and `Write`
(`dist/acp-agent.js:5953-5980`) that emits a `tool_call_update` whose
`content[]` is rebuilt from the tool response's `structuredPatch` by
`toolUpdateFromDiffToolResponse` (`dist/tools.js:898-936`). The bridge's
own comment states the intent: the optimistic content built at tool_use
time carries `oldText: null` and "shows creation semantics regardless of
whether the file existed; the structuredPatch from the hook lets us emit
the real diff".

That update carries only `_meta`, `toolCallId`, `sessionUpdate`,
`content[]` and `locations[]` — no `status`, no `rawInput` — so it hits
the early return.

Two things this feature needs are inside it:

- **The real `oldText`**, i.e. the create-vs-edit discriminator. Null
  only for a genuine pure insertion; non-null whenever the file had
  prior content.
- **`locations[] = {path, line: newStart}`** — per-hunk line numbers
  straight from `structuredPatch`. This is the deferred range data,
  already computed, currently thrown away.

**Do not simply relax the guard.** `MessageWriter:update_tool_call_block`
merges partials via `tbl_deep_extend("force", …)`, which merges
list-valued `diff.old` / `diff.new` element-by-element. A hook diff
carrying context lines would corrupt an Edit's tracker data (and with it
`cached_diff_blocks` and the trust ranges) while the rendered diff stays
frozen. The fix is to recognise this update shape specifically and
surface its payload as dedicated fields (e.g. `file_existed`,
`hunk_lines`), not to let it merge into `diff`.

This is a bug in its own right — the bridge is sending data the plugin
asked for and the adapter is dropping it. It may be worth landing
separately, ahead of the panel.

## Data model

An **append-only op log** on the SessionManager instance, plus a
path-keyed index derived from it. Append-only is what makes reversion
handling, persistence and the unseen-marker fall out cheaply.

```
--- @class agentic.ui.FileActivity.Op
--- @field seq integer Monotonic, per session
--- @field tool_call_id string Idempotency key AND provenance (jump to chat)
--- @field path string Absolute, canonicalised
--- @field op "create"|"edit"|"delete"|"read"
--- @field dest_path? string Move destination only
--- @field ranges? { start_line: integer, end_line: integer }[] Captured now, rendered later
```

Derived per-path row: newest op class, op counts, union of ranges, max
seq. The panel renders rows; nothing mutates ops after append.

### `tool_call_id` is the idempotency key

An append whose `tool_call_id` is already in the log is a no-op. Every
existing hook at this call site is idempotent by construction
(`has_edit_range` guards `_try_record_edit_range` at
`session_manager.lua:1034`; `finalize_edit_range` nils its pending
record); an append-only log is not, and there are two real duplicate
sources:

- **Repeated `completed` updates.** The `checktime` debounce at
  `session_manager.lua:1302-1306` exists precisely because completions
  repeat on hook retry cycles.
- **Path A replay.** `session/load` makes the provider re-send every
  `tool_call` / `tool_call_update`, which re-enters the same handlers.
  With the persisted log restored, replay would double-count every path
  and reset every `seq`, making the unseen marker meaningless.

One key solves both. Path A therefore restores the log *and* lets replay
run; the dedupe absorbs it.

### Where it lives

On `SessionManager`, alongside `file_list` / `todo_list` /
`diagnostics_list` (`session_manager.lua:330`). Not module-level: the
multi-tabpage rule forbids shared state, and two sessions in two
tabpages must not share a tally.

**Not on `PermissionManager`**, despite the near-miss below.

### Reset lifecycle — must be specified, not inherited

The defect that disqualifies `_edit_records` (§ near-miss, reason 4) is
an unspecified lifecycle, so this plan owes an explicit one.
`PermissionManager:clear()` has five call sites; the tally must react
differently to them:

| Site | Meaning | Tally |
| --- | --- | --- |
| `init.lua:305` | `stop_generation` (Ctrl-C) | **preserve** |
| `session_manager.lua:2206` | `_do_load_acp_session` | preserve (restored log + dedupe) |
| `session_manager.lua:2346` | `_cancel_session` (`/new`) | **clear** |
| `session_manager.lua:2435` | `switch_provider` | preserve |
| `session_recovery.lua:304` | Path C respawn after usage limit | preserve |

Only `/new` starts a new conversation. Everything else continues the
same one.

## Detection

### Hook sites

Mirror `_try_record_edit_range`: invoke from **both** `_on_tool_call`
(`session_manager.lua:1011`) and `_on_tool_call_update`
(`session_manager.lua:1252`), bailing on terminal status where the
observation must be pre-edit. For claude-agent-acp, top-level tool calls
arrive at phase 1 with **empty `rawInput`** — no `file_path` — so
anything written as "capture at phase 1" simply never fires for the main
case. (Confirmed by `notes/bug-chat-history-drops-tool-call-enrichment.md`,
where the persisted phase-1 `argument` is `""` for every non-subagent
call.)

The terminal-status append belongs in the existing block at
`session_manager.lua:1307-1333`, which already resolves `tracker` and
gates on `FILE_MUTATING_KINDS[kind_key(tracker.kind)]`
(`session_manager.lua:26-32`). Reuse that table rather than introducing a
parallel kind set. Only `status == "completed"` appends; `failed` (which
includes permission rejection) must not.

### Read the merged tracker, not the update

`argument` arrives on an early update and is *absent* from the
`completed` one. Source of truth is `writer.tool_call_blocks[id]`, via
`self:_writer_for(id)`. The adjacent `_last_edited_md` code at
`session_manager.lua:1322-1332` carries the same warning in a comment and
is the pattern to copy.

### Lowercase before dispatching on `kind`

opencode emits capitalised kinds (`"Edit"`); `display_kind` hides the
difference in the chat heading, so a case-sensitive lookup fails
silently. `kind_key()` (`session_manager.lua:35`) already does this — it
exists as a file-local copy in five modules, so keep the dispatch in
`session_manager.lua` rather than adding a sixth.

### create vs edit

Comes from the hook update described in § Prerequisite. `kind` cannot
carry it: claude maps Write to `edit` (`dist/tools.js:100`).

Note that `create` and `write` *are* valid members of the `ToolKind`
alias (`acp_client.lua:1201-1202`) — they are simply not emitted by
claude-agent-acp. A kind-based branch is not wrong, just insufficient.

**Tracker-level caveat.** `oldText` is nullable only on the raw ACP
`content[]` entry. By the time it reaches `writer.tool_call_blocks[id]`
it has been through `safe_split` (`claude_agent_acp_adapter.lua:253`,
`opencode_acp_adapter.lua:143`) and `safe_split(nil)` returns `{}`. So
the tracker-level test is `#tracker.diff.old == 0`, never
`tracker.diff.old == nil`. This is the same guard that makes
`_try_record_edit_range` skip Writes (`session_manager.lua:1047-1049`).

### Delete — not v1

`kind = "delete"` exists in the ACP alias, but claude-agent-acp emits
only `read`, `edit`, `execute`, `search`, `fetch`, `think`, `other` and
`switch_mode` (verified over `dist/tools.js`). Deletions go through Bash
`rm`, i.e. the deferred Execute path. The `delete` op class exists in the
schema and will light up for a provider that emits the kind; it is not a
v1 deliverable.

### Move

`permission_manager.lua:442` has a `raw_input_destination` helper, but no
surveyed provider populates a destination, and claude has no `move` kind
at all. `dest_path` exists in the schema so a bridge that does emit one
is not a migration; nothing renders it in v1.

### Execute — deferred, and here is why

No exact signal exists. Three approaches that look viable and are not:

- **`PermissionRules` effects.** The `Effect` class
  (`lua/agentic/utils/permission_rules.lua:596`) models
  `{kind="write"|"delete", path}`, but only for redirect targets and
  `rm` operands, and only for commands the walker can fully model. It
  bails structurally on most real commands, and it is built for the
  opposite polarity: its silence means "could not model", not "no
  writes". Using it as a detector would under-report silently.
- **PostToolUse hooks.** Give the command string, same as ACP. No file
  list.
- **Recursive `fs_event` on cwd.** Storms from `.git/`, `node_modules`,
  build dirs; also fires on the user's own `:w`.

The one approach that works is **git candidate set + mtime**, per Execute
call: `git status --porcelain -z` yields a small candidate set (`-z`
because quoted and renamed paths otherwise mangle), and `fs_stat` mtime
on each candidate separates "changed during this call" from "was already
dirty at session start".

`lua/agentic/utils/git_files.lua` already owns the git plumbing and the
per-root cache, and is where this belongs — but note it is currently
entirely synchronous (`vim.system(...):wait()`), so async is a new
pattern for that module, not existing behaviour. Its `diff_hunks`
(`git_files.lua:119`) diffs working tree against **index**, so hunks
vanish once the user stages the agent's edits.

Failure modes are user-visible: non-git projects, gitignored paths, files
outside the repo, and misattribution when the user saves a file in
another window mid-call. When it lands it should be behind a config flag,
with rows tagged by provenance (edit-tool vs inferred) rather than
silently mixed. Deletions arrive with it.

### Reads — deferred, but shape for them now

`kind == "read"` gives a real path in `argument`, and the claude adapter
already carries the read range (offset/limit). Adding them later is an
extra op class, a sort tier and a filter — no schema change, which is the
point of keying the log by op rather than assuming edits.

Two rules that must hold when they land:

- reads do **not** count toward the header count, or the ambient signal
  is noise by turn three
- reads sort below every mutation class

### Why search is excluded

For `kind == "search"` the `argument` is the *pattern*, not a file — the
claude adapter rewrites grep→rg and stashes `rawInput.pattern` as
`search_pattern` (`claude_agent_acp_adapter.lua:216-220`). The matched
files exist only inside the formatted output body, which is
provider-formatted text; parsing it is fragile and per-provider.

Beyond fragility there is a semantic objection: Grep with
`output_mode=files_with_matches` means the model never saw those files'
contents, and that is the common case. Listing them as "read" would be
wrong, and a grep across a repo would swamp the list with single-line
hits.

## Existing infrastructure: a near-miss worth documenting

`PermissionManager._edit_records` (`lua/agentic/ui/permission_manager.lua:38`)
is already a registry of completed edits keyed by `tool_call_id`, holding
`{path, start_line, end_line, new_lines}`, populated at exactly the
lifecycle points this feature needs — `record_pending_edit` pre-edit,
`finalize_edit_range` on completed, `drop_pending_edit` on failed. Built
for `/trust` scope safety.

**It cannot be reused as the tally**, for four reasons:

1. `_try_record_edit_range` skips Writes. Not via `diff.all` — that
   field is `rawInput.replace_all` (`claude_agent_acp_adapter.lua:254`),
   a multi-site Edit flag — but via the `#old_lines == 0` guard at
   `session_manager.lua:1047-1049`, since `safe_split(nil)` returns `{}`.
   Either way the new-file case is exactly what it never records.
2. It gates on `kind_key(tracker.kind) == "edit"` — no delete, no read.
3. It requires `TrustSafety.find_unique_subsequence` to succeed; a
   non-unique match is skipped.
4. **Lifecycle mismatch.** `PermissionManager:clear()` wipes
   `_edit_records` (`permission_manager.lua:966`), and four of its five
   call sites continue the same logical conversation — most frequently
   `init.lua:305` (`stop_generation`, i.e. every Ctrl-C). A tally living
   there would silently empty mid-session. See § Reset lifecycle.

What to take from it: the two-phase capture pattern and the hook sites.
The tally gets its own store with its own lifecycle.

## Reversion

Do not detect reversion at edit time. The log stays append-only;
"is this still changed?" is computed lazily when the panel opens:

- tracked file → absent from `git status --porcelain` means reverted
- created file → `fs_stat` fails means it was deleted again
- non-git project → needs a content hash captured at first touch

Reverted rows are hidden by default. Computing at open (not at edit) also
means reconciliation is paid once per toggle, not per tool call.

Note this also fires when the user *commits* the agent's changes — the
row disappears from the panel. Probably the right behaviour (the work
landed), but it is a behaviour, not an accident.

## Line ranges (deferred) — capture in v1 anyway

Two sources, in order of preference:

1. `locations[] = {path, line: newStart}` from the hook update
   (§ Prerequisite) — exact, per hunk, no matching required.
2. `ToolCallBlock.cached_diff_blocks` (`message_writer.lua:97`), which
   holds `start_line`/`end_line` per hunk from render time.

Source 2 is unreliable across a restore, which is why the range has to be
persisted rather than recomputed. On Path B, `cached_diff_blocks` *is*
recreated (`tool_call_renderer.lua:714`), but `extract_diff_blocks`
matches OLD text against now-post-edit disk (`tool_call_diff.lua:59-89`)
and typically finds nothing — the ranges come back wrong or empty, not
absent. Persist the range at capture time.

This is the one piece where deferring costs something, hence `ranges` in
the v1 schema even though v1 does not render it.

## Persistence

Persist the op log in the session JSON via `ChatHistory`. It cannot be
derived from replay: on Path B, `SessionRestore.replay_messages`
(`session_restore.lua:346-357`) repopulates the chat buffer by calling
`writer:write_tool_call_block` **directly**, bypassing `SessionManager`'s
tool-call handlers entirely. Nothing would append. (The frequently-cited
"Path B collapses tool calls into prose" is a different mechanism —
`ChatHistory.prepend_restored_messages`, which governs what the *model*
sees, not what the client renders.)

On Path A the log is restored and replay re-fires the handlers; the
`tool_call_id` dedupe absorbs the duplicates.

`ChatHistory.save` and `.load` are explicit field whitelists
(`ui/chat_history.lua:191-202` and `:247-254`), so persisting means
editing both plus the `StorageData` class — not just appending a field to
an instance.

`last_viewed_seq` persists alongside, so the unseen marker survives
resume — which is the killed-and-resumed case the feature is for.

## UI

### Panel mechanism — not the dynamic-window path

`open_or_resize_dynamic_window` (`widget_layout.lua:162-192`; `:292` is
the `files` call site) is driven entirely by buffer content: empty buffer
⇒ close the window and clear `win_nrs`; non-empty ⇒ open it. It runs
inside `show_layout`, i.e. on every `ChatWidget:show()`, which the
`FileList` / `DiagnosticsList` callbacks trigger routinely. A tally panel
on that path would force itself open the moment the agent edits a file,
and force itself closed whenever the list is empty — the opposite of a
toggle.

The precedent for a manually-toggled panel is the subagent split:
`WidgetLayout.open_subagent` (`widget_layout.lua:396`) plus
`close_optional_window` (`:434`), wrapped as
`ChatWidget:open_subagent_window` / `close_subagent_window`
(`chat_widget.lua:1565-1572`). `show_layout` never touches it, so an
imperative open/close survives re-layout. Model the new panel on that.

### Ambient count goes in the chat header

`render_header` writes into the *panel's own* winbar and buffer name
(`window_decoration.lua:191-203`). A closed panel has no window and no
header, so a count rendered there is invisible exactly when the panel is
toggled off — its normal state. Put the count in the chat header instead,
via `self.widget:render_header("chat", …)`, where `HeaderParts.context`
already carries the context percentage and trust state.

### Naming

New panel: internal key `activity`, title `" Files"`. Existing
referenced-files panel: key stays `files` (it is public config API —
`Config.windows.files`, `Config.headers.files` — so renaming it breaks
user configs), title changes from `" Referenced Files"` to
`" File Injections"`.

Retitling is not breaking; rekeying is. `activity` rather than `changes`
because reads are expected to land in the same panel behind a filter, at
which point "changes" would be wrong.

A visible title is optional — the winbar is only written when
`Config.winbar` is set (`window_decoration.lua:191`), and a user
`Config.headers` function returning `""` suppresses it
(`resolve_header_text:90`). But a `title` string is structurally
required: it becomes the buffer name, which tabline plugins and the
`AgenticHeadersChanged` pipeline consume.

### Row format

```
+ src/bar.lua        ●
~ src/foo.lua        ●
~ lua/agentic/x.lua
```

`+` created, `~` edited (`-` deleted and `·` read, later). One row per
path. A path both read and edited is one row, marked by its mutation —
which is why op class is a *column*, not a section: a path-keyed list
cannot put the same row in two sections.

`●` marks rows whose newest op exceeds `last_viewed_seq`, i.e. changed
since the panel was last open. Bumped on panel close. The marker is
per-view, not per-op — three edits since you last looked is one dot; edit
counts, if ever wanted, belong in the row data, not in the unseen signal.

An empty tally must still render a placeholder line, not an empty buffer,
if any code path shares the dynamic-window helper.

### Sort

Composed tiers:

1. op class — created / edited / deleted, then read-only
2. location — inside project root, then outside, then scratch (`/tmp`,
   `$TMPDIR`)
3. within tier — alphabetical on the canonical path

Alphabetical, not insertion order: directory grouping emerges, and rows
are findable by guessing. Insertion order's one advantage is that an
append never shifts an existing row, which matters only while the panel
is open — and it is a toggle, normally closed while the agent works.
Insertion order also interacts badly with tiering: tiers already destroy
global chronology, so it would survive only *within* a tier — a partial
chronology that reads like a real one.

Recency-first is explicitly rejected: "what did it just touch" is what
the chat buffer answers.

### Path canonicalisation

`tracker.argument` may be relative or `~`-prefixed — it has been through
`FileSystem.to_smart_path` (`utils/file_system.lua:200`, `:p:~:.`). Use
the same expression `_try_record_edit_range` uses
(`session_manager.lua:1056-1059`):

```lua
vim.fs.normalize(vim.fn.fnamemodify(arg, ":p"), { expand_env = false })
```

or the tally and `_edit_records` will disagree about the same file.

**`fs_realpath` is not usable at capture time for creates.**
`vim.uv.fs_realpath` returns nil for a path that does not exist yet,
which is every new file at the moment it is recorded. And
`vim.fs.normalize` does *not* resolve symlinks — `/tmp/foo` stays
`/tmp/foo`. This matters because on macOS `/tmp` symlinks to
`/private/tmp`, and both forms will appear (this setup has `/tmp` as an
additional working directory, and providers report whichever form they
were handed). Resolve the deepest existing ancestor and re-join the tail,
or defer symlink resolution to panel-open time.

### Keymaps

The toggle is a widget-scope binding and belongs in
`Config.keymaps.widget` (repo CLAUDE.md: all user-configurable options
live in `config_default.lua`). Panel-internal keys (`<CR>` to jump, the
read filter) may be hardcoded — `FileList` hardcodes `d`
(`ui/file_list.lua:89`) — but the plan should say which.

`<CR>` jumps to the file; `ui/diff_jump.lua` already models chat→file
navigation. A second action exports the list to the quickfix list, giving
`:cdo` power without the panel *owning* the user's quickfix list, which
is global and would collide across tabpages.

## Structure

| File | Role |
| --- | --- |
| `lua/agentic/ui/file_activity.lua` | New. Mirrors `file_list.lua` / `diagnostics_list.lua`: owns the op log, `record(op)`, `rows()` (path index + sort), `render()`, `serialize()` / `from_storage()`, buffer-local keymaps via `BufHelpers.keymap_set`. Instantiated in `SessionManager:new` beside `self.file_list` (`session_manager.lua:330`). |
| `session_manager.lua` | `_record_file_op(tool_call_id)` beside `_try_record_edit_range`, called from the same two sites. Lives here, not in the panel class — it needs `_writer_for` and the tracker. |
| `claude_agent_acp_adapter.lua` | The § Prerequisite fix: recognise the hook update, surface `file_existed` + `hunk_lines`. |
| `utils/git_files.lua` | `git status --porcelain -z` and the reversion probe. It already owns `is_tracked` / `diff_hunks` and the per-root cache. |
| `ui/chat_history.lua` | `StorageData` field, plus both whitelists. |

Wiring checklist for the new panel — the existing panels each touch all
six:

1. `PanelNames` alias (`chat_widget.lua:14`)
2. buffer + filetype in `ChatWidget:_create_buf_nrs` (`chat_widget.lua:1396`)
3. `WINDOW_HEADERS` entry (`window_decoration.lua:10-30`)
4. `Config.windows.activity` entry **and** its
   `@class agentic.UserConfig.Windows.Activity` + `@field` on
   `agentic.UserConfig.Windows` (`config_default.lua:183-211`)
5. `Config.keymaps.widget` toggle binding
6. `syntax/AgenticActivity.vim` if rows get highlighting beyond extmarks

## Open questions

- **Subagent attribution.** Task-spawned edits arrive tagged with
  `parentToolUseId` and are routed to a separate buffer. Do they enter
  the tally unmarked, marked, or not at all?
- **Reconciliation timing.** `git status --porcelain` per panel-open is
  cheap on a normal repo but not free on a large dirty one. Render stale
  rows immediately and refresh async, or block on the first open?
