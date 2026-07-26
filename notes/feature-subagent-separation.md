# Plan: separating subagent work in the chat

## Problem

When Claude spawns a subagent (the `Task` tool), the subagent's prose and tool
calls render inline in the main chat, interleaved with the main agent's own
output. There is no way to tell which content is the main agent's and which is a
subagent's, and parallel subagents mix together. The user also cannot steer a
running subagent — over ACP, `session/prompt` addresses the session as a whole
(routed to the main agent), and a `Task` subagent is an autonomous, one-way,
view-only detour.

## v1: split subagent work into a second buffer

Route all subagent content into a dedicated **`subagents`** buffer, shown in a
vertical split beside the main **`chat`** buffer. The main chat then holds only
main-agent content, so "main vs subagent" is answered by *which buffer you are
reading* — no per-line marker needed. The subagents buffer accumulates the full
session (like the main chat); telling parallel subagents apart *within* it is
deferred to v2.

## The wire signal (`parentToolUseId`)

Verified against `claude-agent-acp` 0.54.1 (`dist/acp-agent.js`).

Every subagent notification is tagged with the spawning `Task` tool's id in
`update._meta.claudeCode.parentToolUseId`; top-level (main-agent) notifications
omit the field.

| Origin | `_meta.claudeCode.parentToolUseId` |
| --- | --- |
| Main agent | absent |
| Subagent spawned by `Task` `toolu_X` | `"toolu_X"` |
| Grandchild subagent (spawned by a subagent) | its *immediate* parent's `Task` id (non-null) |

- Live streaming goes through `streamEventToAcpNotifications` (`:3837`), which
  passes `parentToolUseId: message.parent_tool_use_id` **unconditionally** into
  `toAcpNotifications`. So subagent prose, thinking, and tool calls all stream
  to the client, each tagged (subagent thinking included).
- The consolidated `assistant`-message path (`:1564`) *drops* subagent
  text/thinking — but only to avoid double-emitting what already streamed live.
- The routing key is a boolean: **`parentToolUseId` present ⟺ subagent content.**
  A repo-wide grep for `parentToolUseId` returns zero hits — nothing reads it
  today.

### The `Task` block and result stay in the main chat

The subagent-spawn tool is **`Task`** (singular; *not* the `TaskCreate/Update/
List/Get` todo tools). Its `tool_use` is emitted by the main agent, so its
message has `parent_tool_use_id === null` — both the initial `tool_call` and the
completed `tool_call_update` are **untagged** → main chat. The completed update
sets `rawOutput` to the subagent's **final report**, which the plugin already
renders as the `SubAgent` block body (`claude_agent_acp_adapter.lua:116`,
`extract_content_body`; SubAgent kind detection at `:156-166`).

So the split falls exactly right with no extra work: **main chat = the `Task`
spawn block + the subagent's final result; subagents buffer = the working
detail** (interim prose + the subagent's own tool calls).

## Routing: one ownership map

Tool-call *updates* are partial and the `parentToolUseId` tag is not reliably
present on them (the completed `tool_call_update` often omits `_meta`, like it
omits `argument`). Re-reading the tag per message would split a tool-call block
across buffers. Instead, resolve by **ownership**:

- **Message/thought chunks** route by tag directly — each streamed chunk is
  self-contained and carries its own `parentToolUseId`.
- **Tool-call blocks** route phase-1 by tag: on the initial `tool_call`, read
  `parentToolUseId`, pick the writer, create the block in that writer's
  `tool_call_blocks`. That writer now **owns** the `toolCallId`.
- **Everything after** — `tool_call_update`, permission lookups, the float
  anchor, edit-range recording, and the direct `tool_call_blocks[id]` reads at
  `session_manager.lua:835/932/1085/2122` — resolves the writer via a single
  `SessionManager:_writer_for(tool_call_id)` helper, never by re-reading a tag.

This makes routing immune to whether the bridge tags updates at all.

### Two `MessageWriter` instances

`MessageWriter:new(bufnr, status_indicator)` is fully buffer-bound — every piece
of state (the `tool_call_blocks` tracker, auto-scroll, prose anchor, fold ops,
`WinScrolled` autocmd) lives per-instance on one bufnr, with no shared module
state. So the clean design is two instances:

- `self.message_writer` → `buf_nrs.chat` (main), as today.
- `self.subagent_writer` → `buf_nrs.subagent` (new).
- `writer_for(update)`: `parentToolUseId` present → `subagent_writer`, else main.

Each keeps its own tracker/auto-scroll/fold state; `MessageWriter`'s internals
are untouched. A single writer mutating `self.bufnr` per chunk would corrupt the
tracker (which maps `toolCallId → line position` in one buffer) — not viable.

## The `subagents` buffer

- **Clone of the chat buffer's setup, not a plain panel.** It renders tool-call
  blocks + prose exactly like the main chat, so `_create_buf_nrs` gives it
  `filetype = "AgenticChat"`, `treesitter.start(…, "agentic")`, and the
  `snacks.image` attach — same as `chat` (`chat_widget.lua:926-966`). The
  `todos/code/files/diagnostics` panels are plain markdown; the subagents buffer
  is not.
- **Accumulates the full session** like the main chat. `reset_turn_state` runs
  on **both** writers each turn (mandatory — `MessageWriter` cross-turn flags
  are a hazard if not reset), but resets flags only, never buffer content.
- **`---` divider between subagents.** `emit_divider` fires per-Task in
  `_mark_task_closed` (on the Task's `completed`/`failed` update), separating one
  detour from the next. It no-ops when the writer grew nothing since the last
  divider, so a no-interim-content subagent gets no separator.
- **Own `StatusIndicator`** (the static "generating" indicator, not a spinner —
  see `status_indicator.lua`), so main and subagents each show their own working
  state independently (both can show at once). Driven by a **set of open
  top-level `Task` ids** (`_open_tasks`): a `Task` is marked open on the first
  notification whose kind resolves to `SubAgent`, and released on its
  `completed`/`failed` update; indicator on while the set is non-empty. This is
  the authoritative "a subagent is running" signal (a subagent's lifetime *is*
  its `Task`'s open interval), not a chunk-arrival guess. A **set, not a
  counter**, for two reasons: a streamed top-level `Task`'s initial `tool_call`
  arrives with empty `rawInput`, so its kind only resolves to `SubAgent` on the
  refining `tool_call_update` (marking open must therefore fire on either
  surface, idempotently); and set membership makes a duplicated terminal update
  harmless (a counter would drop twice and stop the indicator while a sibling
  `Task` still runs). Grandchildren keep the parent `Task` open, so nesting needs
  no special-casing.

  **Known gap:** this indicator does not currently fire for the subagents
  buffer (cause unconfirmed); per-window working state is deferred until it is
  debugged.

## Window lifecycle

A vertical split of the main chat (default ~50/50, allocation configurable via
`Config.windows.subagent`). It is a **fixed-size scrolling split** structurally
like the main chat (the `subagent_writer` scrolls internally via its own
auto-scroll) — *not* a content-sized dynamic panel like `code`/`files`, which
would need a relayout per streamed chunk.

- **Auto-open** on first subagent activity of a turn.
- **Manual close** by default; `Config.windows.subagent.auto_close` (default
  false) closes it when the active-`Task` count returns to 0.
- A `_subagent_win_opened_this_turn` flag (reset at turn start) makes auto-open
  fire at most once per turn, so a manual close is not undone by later subagent
  activity in the same turn. (With `auto_close = true` this also means a second
  Task in the same turn will not re-open the split — an acceptable edge for a
  non-default option; re-open would need a `WinClosed` autocmd to tell a manual
  close from the auto-close.)

## Permissions

Subagent tool calls **do** escalate `request_permission` over ACP (confirmed
live). Integration is the *same* ownership model, extended:

- **One queue, no concurrency.** One `PermissionManager` per tab, one queue, one
  float; requests serialize (`permission_manager.lua:765-782`). Main and
  subagent escalations arrive on one ACP session and cannot prompt
  simultaneously. Do **not** add a second manager.
- **Float anchors to the owning window.** `PermissionFloat._find_chat_winid`
  (`permission_float.lua:254`) hardcodes `message_writer.bufnr`, so a subagent
  prompt would pop over the main chat. Resolve the anchor from
  `_writer_for(request.toolCall.toolCallId).bufnr` instead. (`parentToolUseId`
  on the permission payload is unverified and unnecessary — ownership by
  `toolCallId` answers main-vs-subagent authoritatively.)
- **Keymaps.** The numbered response keys are bound over `pairs(self._buf_nrs)`
  (`:1031`), so adding the subagent buffer to `buf_nrs`/`PanelNames` covers it
  for free.
- **Tracker lookups.** Route the permission-path `tool_call_blocks[id]` reads
  through `_writer_for` (`permission_manager.lua:172/266/310/561/825`,
  `session_manager.lua:850/947/1100/2139`, plus the `message_writer.bufnr`
  highlight sites at `permission_manager.lua:833/840`). The subtlest is
  trust-scope edit-range recording (`_try_record_edit_range:850`), which silently
  no-ops for subagent edits if left on the main writer.

## Provider scope

**claude-agent-acp only.** opencode runs subagents in an internal SDK session
not registered with the ACP bridge; their streaming and permission events are
dropped and the subagent's output arrives bundled in the parent `task` tool's
`completed` block (see `opencode-subagent-fix.md`) — untagged, so it stays in
the main chat. The whole design keys on tag-presence, so non-Claude providers
simply never populate the subagents buffer. Nothing to build for graceful
degradation.

## v2: numbering parallel subagents

The subagents buffer interleaves all subagents of a turn. When two or more run
concurrently, each one's tool-call blocks are stamped with a **per-turn ordinal**
(`0`–`9`, single-digit), assigned in spawn order. A lone subagent shows no number.

**Assignment.** An ordinal registry + latch, split across `SessionManager`
(`_task_ordinal`/`_next_ordinal` via `_ordinal_for`; `_numbering_latched` via
`_maybe_latch_numbering`; ordinal assigned once per spawning `parent_tool_use_id`
and stamped onto `tool_call.ordinal` in `_on_tool_call`; all reset at the turn
boundary) and `MessageWriter` (`_numbering_active`, `enable_numbering`,
`_ordinal_sign`). Numbering latches the first time `_open_tasks` reaches two and
stays on for the turn; ordinal `0`'s earlier blocks are backfilled on the flip.
Keying the registry on the spawning Task's id (not the child's per-call
`toolCallId`) numbers *agents*, not calls; grandchildren key on their immediate
parent.

### Placement: stamp every body row

The ordinal replaces **every** `│` body-border sign while numbering is active —
the whole left rail of a numbered block becomes the digit (same highlight as the
border), leaving the `╭─`/`╰─` corners intact. Concealed fence-delimiter rows
receive the digit too but stay zero-height at `conceallevel = 2`, so it simply
does not show there — harmless.

This is structure-agnostic: it does not depend on which rows a kind emits or which
are concealed, so it survives both tool variation and any `conceallevel`.

- **Live render:** `ExtmarkBlock.render_block` stamps `opts.ordinal` in place of
  `SIGNS.BODY` on every body row — `sign_text = opts.ordinal or SIGNS.BODY`, no
  per-row selection. `render_decorations` passes only the sign (no `ordinal_rows`).
- **Backfill (`_stamp_ordinal`):** restamp every body decoration id to the digit
  via `restamp_border` (`ExtmarkBlock.set_sign`), reusing the ids. The ids run
  `[header, body_1 .. body_n, footer, (dim?)]`; header (`ids[1]`) and footer keep
  their corner signs, every body id in between takes the digit.

Tests assert the digit replaces the body signs (`│ ` count → `0 ` count) rather
than asserting a specific row, and cover a fence-less `read` block, a multi-fence
`execute` block, live-then-update, and backfill.

### Migrating the current diff

The uncommitted numbering diff is mostly reusable — pivot surgically, do not
rebuild.

- **Keep** the assignment/latch machinery (`session_manager.lua` and its
  `_ordinal_for`/latch tests) and the sign primitives (`enable_numbering`,
  `_ordinal_sign`, `set_sign`, `restamp_border`, the `ordinal` field/param) —
  already correct, carry over untouched.
- **Delete** the first/last content-row plumbing: the `record_content()` helper
  and `content_rows` field threaded through every branch of `prepare_block_lines`,
  the `ordinal_rows` logic in `render_decorations`/`render_block`, and the
  offset→id mapping in `_stamp_ordinal`.
- **Edit** the three stamp sites named in Placement — only `_stamp_ordinal`'s
  backfill loop is a real rewrite (offset list → the block's body-row id range).

The existing tests bake in a two-signs-per-block model: the numbering assertions
count two signs (`count(decoration_signs(), "0 ") == 2`); a full rail makes the
count the block's body-row count, and the "first and last content row" case needs
retitling. Helpers and scaffolding survive.

### Accepted edges

- A block whose every visible body row is concealed (a fully-folded single-region
  body) shows the digit only where a row is visible; a bodyless tool-call block
  (header + footer only) has no body row and shows no number. The concurrency latch
  keys on top-level Tasks (`_open_tasks`), so a parent+grandchild overlap may not
  trip it — deep-nesting numbering is imprecise, in line with nesting being an edge
  elsewhere. All left as-is.

### Ruled out

- **`statuscolumn`.** Unnecessary — a single-digit ordinal fits the existing
  `sign_text` cell, so no statuscolumn function is needed and there is no shared
  rewrite with `feature-diff-line-numbers.md`. That feature needs statuscolumn on
  its own account (up-to-5-digit line numbers beside a border), independent of
  this one.
- **Per-agent colour.** A distinct bright colour per agent reads as rainbow and
  pulls attention; a subtle tint is too weak to distinguish at a glance. The
  number is the signal; borders stay one colour.
- **Sticky-in-view number.** Pinning the ordinal to the top of a block's visible
  portion as it scrolls has no native primitive (no viewport-sticky sign). It
  would need a `WinScrolled` handler recomputing the first visible line per
  straddling block — fold-aware topline math (neovim skill § rendering) — too
  brittle for the payoff. The full-rail stamp keeps a number in view for any
  partly-visible block for free instead.

## Deferred (post-v2)

- **Per-agent labels** (`subagent_type` + `description`) as an inline header when
  a new agent's content first appears in the buffer.
- **Focus-by-folding** within the subagents buffer: a keymap that folds every
  block not owned by agent N, reusing `MessageWriter:_close_fold`. Only worth it
  if parallel-subagent interleave proves confusing.
- **Explicit persistence across reloads.** v1 is best-effort: Path A
  (`session/load`) *may* replay tagged subagent chunks (verify); Path B
  (`restore_from_history`) collapses history to a prose prefix, so subagent
  interim is lost. The main chat's `Task` results survive either way. Serialising
  and replaying the second buffer is a clean v2 add if the loss annoys.

## Non-issues

- **Deep nesting.** No tree, ever — only two windows. Any non-null
  `parentToolUseId` (at any depth) → subagents buffer. A grandchild `Task` is
  itself tagged, so its spawn block and result also land there; only the
  top-level `Task` (parent null) stays in the main chat. The `parentToolUseId`
  chain only matters if a tree view is ever built.
- **Concurrent prompts.** Serialized by the single permission queue (above).
