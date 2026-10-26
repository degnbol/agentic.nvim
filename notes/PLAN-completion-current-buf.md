# Plan: completion handler reads the buffer named by the request
Status: reviewed

## Relevant files
- `lua/agentic/completion/lsp_server.lua` — `_make_handlers` (:286-361), completion branch (:303-349)
- `lua/agentic/completion/lsp_server.test.lua` — `complete()` helper (:16-31), `before_each` (:38-42), "no commands stored" case (:187-199), client-path cases (:487-562)
- `lua/agentic/ui/chat_widget.lua` — `_create_new_buf` (:1464-1469) names every panel buffer; `_attach_input` (:1374-1395) attaches the server
- `lua/agentic/ui/window_decoration.lua` — `buffer_name` (:133-144), `agentic://<id>/<panel>[/<title>]`
- Skills: `neovim`, project `.claude/rules/tests.md`

## Background
Bug report: `notes/bug-completion-current-buf.md`.

**Why the handler schedules.** Comment at `lsp_server.lua:304-306`: the
callback must run outside the `<C-x><C-o>` textlock, or the built-in client's
`complete()` raises E565. The schedule stays.

**What the request carries.** Every client request includes
`textDocument.uri` and `position` (`vim.lsp.util.make_position_params`; the
client-path test builds the same shape at `lsp_server.test.lua:507-516`). The
handler already takes `position` from the request (:309-310). Only the buffer
comes from `nvim_get_current_buf()` (:308).

**Why the request is the right source.** One client serves all input buffers:
`vim.lsp.start` reuses a client with the same `name` and `root_dir`
(`$VIMRUNTIME/lua/vim/lsp.lua:119-147`), and `attach` always passes
`name = "agentic_input"`, `root_dir = getcwd()` (`lsp_server.lua:368-377`).
The handler table is therefore not bound to one buffer; the URI is the only
per-request buffer identity. `chat_widget.lua:1467-1468` already states the
input's name is its document URI for this server. Measured on nvim 0.12.6:
`vim.uri_to_bufnr(vim.uri_from_bufnr(b))` returns `b` for `agentic://1/input`,
`agentic://1/input/my title`, and titles with `%`, `#`, `?` and non-ASCII
text. Only the main input attaches the server (`chat_widget.lua:1392`).

**Reachability.** Not reproduced. The current buffer can differ at callback
time only if something changes focus between the request and the next
event-loop turn: keys already in typeahead (mapping, macro, `feedkeys`) or
another scheduled callback that calls `nvim_set_current_win` (e.g.
`ChatWidget:move_cursor_to`, `chat_widget.lua:918-922`). Effect when it does: the
handler reads line `position.line` of the wrong buffer. Slash and word items
come back empty (`States.getSlashCommands` / `getChatBufnr` key on the wrong
buffer), and `@` file items are computed from the wrong buffer's text.
Rare and not an error, but the fix is the general path, not a guard: it
replaces one call.

**The `#lines == 0` guard (:314-317)** is not specific to focus changes. It
also covers a `position.line` past the end after lines were deleted in the
same buffer, and an unloaded buffer (`nvim_buf_get_lines` returns `{}`).
Without it `line_text:sub` (:325) errors on `nil`. It stays.

**Tests depend on the old behaviour.** `complete()` sets the current buffer
"so the handler reads from the right one" (:17-18) and sends no
`textDocument`. Test buffers are unnamed, including the child's start buffer
used as `input` in the client-path cases (:493). Measured: an unnamed
buffer's URI is `file://`, and `uri_to_bufnr("file://")` creates a new buffer
instead of returning the original. With change 1 and only the unit-test
buffers named, the client-path case fails (`completed_line` is `vim.NIL`).
Every test buffer that receives a request must have a name.

## Changes
1. `lsp_server.lua:308` — replace `vim.api.nvim_get_current_buf()` with
   `vim.uri_to_bufnr(params.textDocument.uri)`. No other handler change.
2. `lsp_server.test.lua`
   - `before_each` (:39) and the "no commands stored" case (:189): give each
     buffer a scheme name, e.g. `nvim_buf_set_name(buf, "agentic://test/input")`
     (distinct names per buffer; `agentic://test/input2` for `buf2`).
   - Client-path `before_each` (:493): name the child's input,
     `vim.api.nvim_buf_set_name(input, "agentic://test/input")`, before
     `attach`.
   - `complete()` (:16-31): pass
     `textDocument = { uri = vim.uri_from_bufnr(bufnr) }`; drop the
     `nvim_set_current_buf` (:18) and its comment (:17).
   - New case in "slash command completion": it cannot use `complete()`,
     which drains internally (:29). Call `handlers.request` for `bufnr`
     (`"/"` on line 0, trigger `"/"`), then `nvim_set_current_buf` to a new
     scratch buffer, then `deferred.drain()`. Assert the items include
     `context` and `plan`. Revert the capture and delete the scratch buffer
     with `MiniTest.finally`. Measured in a copy of the repo: the case fails
     on the current code and passes after change 1; the full file passes.

## Expected outcome
Completion is computed for the buffer the client asked about, whatever window
has focus when the scheduled callback runs.

## Non-goals
- Removing the `vim.schedule` (needed for E565) or the `#lines == 0` guard.
- Handling a URI that no longer names a loaded buffer (input wiped within the
  same tick): `uri_to_bufnr` then adds an unlisted, unloaded buffer and the
  guard returns no items. Session ids only increase
  (`session_manager.lua:335`), so that name is never reused. No extra code
  for that.

## Open questions
None.
