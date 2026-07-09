# agentic.nvim: prompt navigation via marker extmarks — implementation spec

Status: reviewed by plan-reviewer 2026-07-09; blocking findings incorporated.

## Problem

`[[` / `]]` (and the `❯` prompt signs) in the chat buffer key on an exact
text match `line == "##"` in `ChatWidget:_setup_prompt_signs`
(`lua/agentic/ui/chat_widget.lua:614-668`). Commit c41c1ee changed live
prompt rendering: `prompt_heading_lines` (`session_manager.lua:48`) now
writes `## <first prompt line>` so treesitter-context pins the prompt as a
breadcrumb. The bare `##` no longer exists for live prompts → navigation
and signs are dead.

Matching `^## ` instead is not acceptable: the agent writes free markdown,
so any H2 it emits becomes a false prompt anchor. Text content is no longer
a reliable prompt discriminator.

Additional divergence: `SessionRestore.replay_messages`
(`session_restore.lua:332-342`) still writes the old bare `##` heading, so
restored prompts render differently from live ones.

## Design: marker extmarks placed at write time

Place an extmark in a dedicated namespace on the prompt heading line at the
moment the prompt is written to the chat buffer. Signs and navigation both
read from the namespace; no text scanning anywhere.

### Resume / restore story

Extmarks are buffer-local and non-persistent — but so is the buffer text.
Every path that brings a session back either **re-writes prompts through
the choke point** (markers rebuilt for free) or **preserves the buffer**
(markers persist). No separate rebuild pass. Verified paths:

| Path | Mechanism |
| --- | --- |
| ACP `session/load` replay | `widget:clear()` (session_manager.lua:2093) then provider re-sends `user_message_chunk`; handler at `session_manager.lua:508-540` → choke point |
| Local restore: `restore_from_history` both branches (`session_manager.lua:2547-2569`), `restart_session` (`:2574`), `_fallback_restore_from_local` (`:2201-2214`) | `SessionRestore.replay_messages` → choke point |
| `respawn_after_usage_limit` (`session_recovery.lua:292-339`) | **No replay.** `restore_mode = true` skips `_cancel_session`, so `widget:clear()` never runs — buffer and extmarks are preserved as-is; `on_created` only swaps history state |
| Widget hide/show within a session | buffers persist (`ChatWidget:hide` `chat_widget.lua:157-204`; only `destroy` deletes) → extmarks persist |

Inverse hazard: `ChatWidget:clear()` (`chat_widget.lua:207`) wipes lines
with `nvim_buf_set_lines(0,-1,{""})`, which collapses marks in the
namespace onto `(0,0)` **without deleting them** (spike-verified) — stale
marks would make `[[`/`]]` jump to a phantom prompt at the top. Clear the
prompt namespace there explicitly.

## Implementation

### 1. `MessageWriter.NS_PROMPT_MARKERS` (message_writer.lua)

Module-level namespace exported as a field, following the
`Renderer.NS_TOOL_BLOCKS` precedent:

```lua
MessageWriter.NS_PROMPT_MARKERS =
    vim.api.nvim_create_namespace("agentic_prompt_signs")
```

Global namespace + buffer-scoped marks is sanctioned by
`.claude/rules/multi-tabpage.md`. Delete the `nvim_create_namespace` call
inside `_setup_prompt_signs` (`chat_widget.lua:615`).

### 2. `MessageWriter:write_user_prompt` (message_writer.lua)

**Standalone body — do NOT delegate to `write_message`** (its trailing
blank is inside its own closure; the reflow flush and post-append row
computation can't be hosted in a wrapper).

```lua
--- Write a user prompt to the chat buffer and mark its heading line with
--- a prompt-marker extmark (sign + [[ / ]] navigation anchor).
--- @param text string Raw prompt text (first line becomes the ## heading)
--- @param extra_lines string[]|nil Display-only lines appended after the
---        prompt body (selected code / referenced files / diagnostics)
function MessageWriter:write_user_prompt(text, extra_lines)
```

Steps, in order:

1. Build lines: `prompt_heading_lines(text)` (helper **moves here** from
   `session_manager.lua:48` — it's a rendering concern), then
   `vim.list_extend(lines, extra_lines or {})`, then append the
   `"\n---\n"` separator (the method owns it; all three call sites
   currently compose heading-first / separator-last, verified).
2. Flatten multi-line entries + wrap, matching `write_message`:
   `vim.split(table.concat(lines, "\n"), "\n", { plain = true })` →
   `TextWrap.wrap_prose(flat, self:_get_wrap_width())`.
3. `self:_auto_scroll(self.bufnr)` **before** any write (discipline rule).
4. Inside `_with_modifiable_suppressed`:
   a. `self:_reflow_chunks(bufnr, true)` — **required.** `right_gravity =
      false` survives appends but NOT `set_lines` over a range containing
      the mark row (spike-verified: mark collapses to range start).
      `_chunk_start_line` is not reset by prompt writes, so during replay
      (thought chunk → prompt → thought chunk) the reflow range would span
      the heading and drag the marker. Mirrors the existing guard in
      `write_tool_call_block` (comment at message_writer.lua:1075-1079).
   b. `self:_append_lines(flat_lines)`; `self:_append_lines({ "" })`.
   c. Compute the heading row **after** the append:
      `local heading_row = vim.api.nvim_buf_line_count(bufnr) - #flat_lines - 1`
      (the `-1` for the trailing blank). Pre-capture is WRONG on an empty
      buffer: `_append_lines` (message_writer.lua:789-808) replaces row 0
      when the buffer is empty (`line_count == 1`), so pre-capture yields
      row 1 for a heading at row 0 — and `session/load` replay hits this
      (buffer cleared before first chunk). Post-append math is correct in
      both cases (`= 0` empty, `= count_before` non-empty). Precedent:
      `write_error_message`'s `was_empty` handling (message_writer.lua:422-431).
   d. Place the marker:
      ```lua
      vim.api.nvim_buf_set_extmark(
          bufnr, MessageWriter.NS_PROMPT_MARKERS, heading_row, 0, {
              right_gravity = false,
              sign_text = "❯ ",
              sign_hl_group = "NonText",
          })
      ```
      The sign rides on the marker itself — replaces the `TextChanged`
      full-buffer re-scan.

Note: `generate_user_message` concats with `"\n"` and `write_message`
re-splits, so string vs line-list input was already behaviourally
identical (acp_payloads.lua:20-29) — no rendering change from the
restructure itself.

### 3. Call-site conversions (exactly three)

- **Live submit** (`session_manager.lua:1663-1782`): keep composing the
  selection/referenced-files/diagnostics display lines, but into a local
  `extra_lines` list; drop the `prompt_heading_lines` call, the
  `"\n---\n"` insert, and the `ACPPayloads.generate_user_message` +
  `write_message` pair. Call
  `self.message_writer:write_user_prompt(input_text, extra_lines)`.
  Wire-payload (`prompt`) composition is untouched.
- **`user_message_chunk` replay handler** (`session_manager.lua:528-532`):
  → `self.message_writer:write_user_prompt(text)`. Drop the local heading
  building and separator insert.
- **`SessionRestore.replay_messages` user branch**
  (`session_restore.lua:334-342`): → `writer:write_user_prompt(msg.text)`.
  This unifies restored prompts with the live `## <first line>` heading
  (they gain the c41c1ea breadcrumb behaviour; user-visible change is one
  line fewer per restored prompt — intended).

Welcome messages (`session_manager.lua:2014`, `:2190`) stay on
`write_message` and get no markers (verified they don't route through the
new method).

**Subagents buffer: nothing to do.** `subagent_writer`
(`session_manager.lua:290`) is a full MessageWriter, so the method is
callable there, but no code path routes user prompts to it
(`user_message_chunk` always targets `message_writer`;
`is_subagent_update` gates only agent/thought chunks), and `[[`/`]]`
keymaps exist only on the chat buffer. Do not invent marker plumbing for
it.

### 4. Navigation rewrite (`chat_widget.lua:614-668`)

- Delete the `TextChanged` autocmd and `place_prompt_signs` scan.
- Read `MessageWriter.NS_PROMPT_MARKERS`; one
  `nvim_buf_get_extmarks(chat_buf, NS, 0, -1, {})` call per keypress
  (marks are in traversal order; mark count = prompt count, small).
- Semantics, 0-indexed with `cur = nvim_win_get_cursor(0)[1] - 1`:
  - `[[` → jump to the **greatest mark row `< cur`** (strictly earlier in
    the buffer than the cursor line).
  - `]]` → jump to the **smallest mark row `> cur`** (strictly later).
  - No match → no-op (matches current behaviour).
- `nvim_win_set_cursor(0, { row + 1, 0 })`. No `zv`: prompt headings are
  never inside folds (folds cover fence content only) — matches current
  behaviour.
- Keymap config keys unchanged (`keymaps.chat.prev_prompt` / `next_prompt`,
  defaulted in `config_default.lua:273-274`).

### 5. Cleanup

- `ChatWidget:clear()` (`chat_widget.lua:207`): after the line wipe, add
  `nvim_buf_clear_namespace(self.buf_nrs.chat, MessageWriter.NS_PROMPT_MARKERS, 0, -1)`
  — necessary and sufficient against the collapsed-stale-mark hazard.
- Remove `prompt_heading_lines` from `session_manager.lua`.
- No `doc/agentic.txt` change: `[[`/`]]` are documented as bare
  key/description rows (`doc/agentic.txt:456-459`) — behaviour is
  unchanged from the user's perspective.

## Edge cases (all resolved)

- **Empty buffer / first prompt at row 0** — handled by post-append row
  math (§2 step 4c).
- **Marker under `_reflow_chunks` set_lines** — handled by the flush-first
  rule (§2 step 4a).
- **Marker under `update_tool_call_block` set_lines** — safe: its range is
  exclusive of lines below the block; marks only shift.
- **`clear()` stale marks** — handled (§5).
- **Single-line prompt** — heading only; marker on it.
- **Agent-emitted `## ` headings** — ignored by design (no marker).
- **Heading wrap** — non-issue: `wrap_prose` never wraps headings
  (`is_heading` guard, text_wrap.lua:122-125, 405); the first flat line is
  the heading unconditionally.
- **Multi-tabpage** — buffer-scoped marks, buffer-local keymaps; the
  module-level namespace is fine per the rules file.

## Tests

Per `.claude/rules/tests.md` co-location:

- `lua/agentic/ui/message_writer.test.lua`:
  - marker placed on heading row on a live `write_user_prompt` into a
    non-empty buffer;
  - marker at row 0 when the buffer is empty (the `session/load` shape);
  - marker survives a chunk-reflow: `write_message_chunk` (thought) →
    `write_user_prompt` → `write_message_chunk` → `append_separator`;
    assert the mark still sits on the `## ` line.
- `lua/agentic/ui/chat_widget.test.lua`:
  - `[[`/`]]` land on marker rows and skip an agent-authored `## Foo`
    line written via `write_message_chunk`;
  - `clear()` leaves `nvim_buf_get_extmarks` empty for the namespace.
- **Existing test breakage**: `session_restore.test.lua:637-658` stubs the
  writer with `write_message`/`write_message_chunk`/`write_tool_call_block`
  and asserts `write_message` is called twice (user + agent). Add
  `write_user_prompt` to the stub; assertion becomes one call each.

## Validation

- `make validate`
- Manual: submit multi-line prompt → sign on heading, `[[`/`]]` work;
  agent response containing `## Foo` is skipped; restore a session from
  the picker → navigation works across restored prompts; `/clear` then
  `[[` → no phantom jump to line 1.
