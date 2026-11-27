# Bug: main panels lose buffer options, b-vars and keymaps after `:bd`

Line numbers are against `cc07515` + working tree.

`:bd` on a named scratch buffer resets all of its buffer-local state: options
(`filetype`, `buftype`, `bufhidden`, `modifiable`, `swapfile`), b-vars and
buffer-local keymaps. Buffer-local autocmds stay. `bufload` and `BufReadCmd`
do not restore the state. `:bunload` and `:e!` keep it. This was checked with
a spike.

Panels that set up their buffer again on `BufReadCmd`, and recover:
- subagent transcript: `widget:setup_panel_buf` and `handlers.setup_buf`
  (`subagent_transcript.lua:97-106`)
- subagent message input: `setup()` (`subagent_input.lua:29-44`, `:56`)

The chat needs no fix: `:bd` on it ends the session
(`SessionManager:_setup_buffer_lifecycle`, `session_manager.lua:634`).

Panels that do not set up their buffer again, and stay broken after `:bd`:
- todos, code, files, diagnostics, activity and info: the `BufReadCmd` of
  `SessionManager:_watch_panel_buf` only renders the content
  (`PANEL_RELOADS`).
- input: its `BufReadCmd` in `ChatWidget:_setup_input` only calls
  `_attach_input`.

These panels lose:
- `filetype`, so also ftplugin options such as `'includeexpr'`
- `buftype`, `bufhidden`, `swapfile`, and `modifiable=false` (the list
  panels become editable)
- `agentic_session_id`, `agentic_window` and `agentic_header`
- the widget keymaps (`ChatWidget:_bind_buf_keymaps`) and the session keymaps
  (`SessionManager:_bind_session_keymaps`, bound at
  `session_manager.lua:473-478`)

## Fix

In each of those `BufReadCmd` callbacks, call
`widget:setup_panel_buf(bufnr, panel)`, which applies the panel's options,
b-vars and widget keymaps, then `SessionManager:_setup_panel_buf(panel,
bufnr)`, then set the header context again with `ChatWidget:render_header`. Without
`agentic_header`, `WindowDecoration.get_header` gives the panel's default
title and no context.
