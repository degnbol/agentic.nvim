# Plan: Session buffer names that `:e` and `gf` open
Status: reviewed spec

## Relevant files

- `lua/agentic/ui/window_decoration.lua` — `buffer_name` (moves out)
- `lua/agentic/ui/chat_widget.lua` — `_create_new_buf`, `_apply_buf_opts`, `set_chat_title`, `panel_buf_opts`, `panel_buf`
- `lua/agentic/ui/subagent_transcript.lua` — `name_tail`, `SubagentTranscript:new`
- `lua/agentic/ui/subagent_input.lua` — `SubagentInput:new`
- `lua/agentic/subagents.lua` — `buffer_name`, `transcript`, `_open_agent`, `_open_input`, `add_history_transcripts`, `_merge_block_fields`, `_agent_label`, `child_of_buf`
- `lua/agentic/background_session.lua` — `_open_transcript`
- `lua/agentic/bootstrap.lua` — the no-op `agentic://*` BufReadCmd
- `lua/agentic/session_resume.lua` — `resume`, `pick`, `show_picker`, `write_row`
- `lua/agentic/session_registry.lua` — `session_for_acp_id`, `by_id`
- `lua/agentic/session_manager.lua` — `_adopt_session`, `_do_load_acp_session`, `_pending_load`, `_session_changed`, `_reset_conversation`, `switch_provider`, `_setup_session_buf`, `_open_fork_link`, `_fork_link_at`, `_tagfunc`, the permission notice (`fnamemodify(..., ":t")`)
- `lua/agentic/ui/permission_manager.lua`, `lua/agentic/ui/permission_float.lua` — float title from `:t` of the buffer name
- `lua/agentic/ui/message_writer.lua` — `write_fork_link`
- `lua/agentic/ui/diff_jump.lua` — `set_goto_file_keymaps` (`open_at`)
- `lua/agentic/utils/buf_helpers.lua` — `rename`, `named`
- `lua/agentic/completion/lsp_server.lua` — `_make_handlers` (buffer lookup)
- `lua/agentic/init.lua` — `load_acp_session`
- Tests that pin today's names or signatures: `lua/agentic/ui/window_decoration.test.lua`, `lua/agentic/ui/subagent_transcript.test.lua`, `lua/agentic/ui/chat_widget.test.lua` ("keeps the plain title in the buffer name"), `lua/agentic/ui/diff_jump.test.lua` (`open_at`), `lua/agentic/session_resume.test.lua` (`resume(ref, mods)`), `tests/integration/test_native_subagents.lua`, `tests/integration/test_buffer_naming.lua`, `tests/integration/test_goto_file.lua`, `tests/integration/test_fork.lua`
- Docs: `doc/agentic.txt` (`*agentic-fork*`, `*agentic-subagents*`), `.claude/skills/session-lifecycle/SKILL.md` (buffer names), `.claude/rules/session-isolation.md` (global BufReadCmd)
- Skills: `session-lifecycle`, `rendering`; neovim skill `references/ui.md`, `references/autocmds.md`

## Background

A fork link row shows `Forked from <8-char id>`. Opening the other chat
needs custom code: `set_goto_file_keymaps` takes an `open_at` callback,
`_open_fork_link` finds the link by the notice's extmark id
(`_fork_link_at`) and calls `SessionResume.resume`. Neovim already has this
mechanism: `gf`, `<C-w>f`, `<C-w>gf`, `:e`, `:sp`, `:tabe` open a name, and
a `BufReadCmd` decides what a name holds. `gf` on a `scheme://` name with
no buffer fires the BufReadCmd (scheme of 2+ letters).

The names cannot carry that today. `agentic://<n>/<panel>[/<title>]` keys
on `<n>` = `SessionManager.id`, a counter of the running editor: it has no
meaning after a restart, and a closed chat has none. Titles and subagent
labels in names change after the buffer is named (`/rename`;
`Subagents:update` relabels), and a title with spaces cuts `<cfile>` short.
The `agentic://*` BufReadCmd in `bootstrap.lua` is a no-op that exists only
so tag jumps accept the names.

Every session buffer belongs to one agent, so every one takes the ACP
session id as its key, and no title or label. The name is then fixed for
the life of the ACP session. The title stays in the winbar header, where
Neovim draws a window's title, and in the fork link row's heading. A title
slug in the name would change on `/rename` and read little better than the
id.

Renaming the input is safe for completion: Neovim's LSP client builds the
URI from the current name on each request (`vim.uri_from_bufnr`), its
change tracking is keyed by bufnr, and the URI it caught at attach only
feeds notifications, which the in-process server ignores.

## Changes

1. New module `lua/agentic/utils/buffer_names.lua`, a pure codec for
   `agentic://<key>[/<sub_id>][/<part>]`:
   - `BufferNames.PANELS`: the list of panel names (today only the type
     alias `ChatWidget.PanelNames` and the local `panel_buf_opts` hold
     them); `chat_widget.lua` uses it.
   - `--- @class agentic.BufferNames.Parts` with `key: string` (ACP
     session id, or `tostring(SessionManager.id)` before the session has
     one), `sub_id?: string` (a subagent's full session id),
     `part?: string` (a `PANELS` value other than `agent`, or `input`
     after a `sub_id`, or `background`).
   - `BufferNames.format(parts: agentic.BufferNames.Parts): string`.
     Callers pass no `part` for the chat and a transcript.
   - `BufferNames.parse(name: string): agentic.BufferNames.Parts|nil`:
     `[key]`; `[key, X]` with `X` in `PANELS` or `background` as `part`,
     else as `sub_id`; `[key, sub_id, "input"]`. Anything else: nil.
     Ids (UUIDs, `ses_…`, `toolu_…`) never equal a panel name.
   - `WindowDecoration.buffer_name` is deleted; callers use `format`.
2. `BufHelpers.claim_name(bufnr: integer, name: string): boolean`: when
   another buffer holds `name`:
   - a loaded buffer with `vim.b.agentic_session_id` (another session's):
     `Logger.notify` ERROR, return false;
   - else show `bufnr` in each window of that buffer
     (`vim.fn.win_findbuf`), then delete it, so `:sp`, `:tabe` and
     `<C-w>gf` keep the window they opened.
   Then `rename`, return true. Replaces the delete-stray-then-rename copies
   in `ChatWidget:_create_new_buf` and `SubagentTranscript:new`; every
   rename below uses it.
3. `ChatWidget`: field `_name_key`, initially `tostring(owner_id)`.
   `ChatWidget:rename_buffers(key: string)` stores it and `claim_name`s
   each valid buffer in `buf_nrs`. `_create_new_buf` names from
   `_name_key`. `set_chat_title` no longer renames the chat; the header
   keeps the title.
4. `SessionManager:_session_changed(session_id, continued)` calls
   `self.widget:rename_buffers(session_id)` and
   `self._subagents:rename_buffers(session_id)`. The latter renames live
   transcripts and message inputs and rewrites each block's `argument`
   (`_merge_block_fields`, then re-render): `switch_provider` adopts a new
   id without resetting `_subagents` or re-rendering.
   `_reset_conversation` calls `self.widget:rename_buffers(tostring(self.id))`,
   so a chat whose next session is never adopted (failed `/new`) stops
   answering to the old id.
5. `SubagentTranscript:new` and `SubagentInput:new` take the full `name`
   (callers `format` it); delete `name_tail`. `BackgroundSession` names
   its transcript `format({ key = <bg session id>, part = "background" })`.
   The permission float and notice show the subagent's label, not `:t` of
   the name: `PermissionManager:new` takes a `title_for(bufnr): string|nil`
   resolver, as it takes `writer_for`, composed from
   `Subagents:child_of_buf` and `Subagents:_agent_label`;
   `PermissionFloat:set_anchor(bufnr, title)`.
6. `SessionResume.resume(ref, opts): agentic.SessionManager|nil` with
   `opts: { mods?: vim.api.keyset.cmd_mods, winid?: integer, on_shown?: fun(session, winid) }`.
   `winid` shows the chat in that window (`ChatWidget:show_in`) and
   ignores `mods`. Returns the session shown (open or created), nil when
   none. A `ref` that carries `cwd`, `provider` and `model` skips
   `read_saved`. Callers: `show_picker`, `pick`, `init.lua`
   `load_acp_session`.
7. `SessionRegistry.session_for_key(key: string): agentic.SessionManager|nil`:
   the session whose `session_id` or `_pending_load.session_id` is `key`,
   else `by_id[tonumber(key)]` when that session has no ACP id yet (a
   numeric name from an earlier editor does not reach a later session).
   `SessionResume.resume` uses it instead of `session_for_acp_id`, so a
   second `:e` during a pending load shows the loading chat.
8. `SessionManager:buf_of(sub_id: string|nil, part: string|nil): integer|nil`
   — pure lookup, makes nothing: chat, valid `widget.buf_nrs[part]`, or
   `Subagents:buf_of(sub_id, part)` reading `agent.transcript.bufnr` /
   `_inputs[sub_id].bufnr` when valid.
9. `SessionResume.open_name(args)`, wired as the `bootstrap.lua`
   `agentic://*` BufReadCmd:
   - `parts = BufferNames.parse(args.match)`; nil, or part `background`:
     return.
   - `session = session_for_key(parts.key)`. Live and
     `session:buf_of(...) == args.buf` (a `:bd`-unloaded Agentic buffer
     reloading; `:bd` clears b-vars): return; its buffer-local
     BufReadCmd refills it.
   - `win = vim.fn.bufwinid(args.buf)`; `-1` (`bufload`, `nvim_buf_call`,
     picker preview): return.
   - Live: the buffer from `buf_of`, else made (`widget:panel_buf(part)`;
     `Subagents:transcript(sub_id)` when `_agents[sub_id]` exists; the
     message input as `_open_input` does). Making it claims the name and
     takes `win` (change 2). A buffer found under an older name: show it
     in `win`, wipe `args.buf` if still valid. Nothing to make: notify
     ERROR "no such subagent".
   - Not live, a chat or transcript name, and `ChatHistory.read_saved(key)`
     finds it: `resume({ session_id = key, cwd, provider, model },
     { winid = win, on_shown = ... })`; `on_shown` shows the transcript of
     `sub_id`. The chat's rename to `key` claims the placeholder.
   - Otherwise (unknown id; panel of a closed session): notify ERROR.
10. Rows that show a name:
    - Fork link: `Forked from|to <name>`, `<name>` =
      `format({ key = link.session_id })`. Delete `_open_fork_link`,
      `_fork_link_at`, and the `open_at` parameter of
      `set_goto_file_keymaps`. Keep `FORK_NOTICE` and the fork exclusion
      in `_tagfunc` (`<C-]>` on the row would otherwise jump to itself).
    - Session message rows (`SessionResume.write_row`): the detail is the
      other end's label, then its name, so a reader sees who and `gf`
      still finds the name.
    - Subagent block name line: the name only; the block's heading already
      shows the label.
11. In-process LSP: resolve the request's buffer with
    `BufHelpers.named(vim.uri_to_fname(uri))` (exact match, makes no
    buffer) instead of `vim.uri_to_bufnr`, which makes an empty buffer for
    a URI caught before a rename. `vim.fn.bufnr` is unfit: it matches
    partial names.
12. Docs: `doc/agentic.txt` names in `*agentic-subagents*`, `gf` on the
    name in a fork link row in `*agentic-fork*`, `:e agentic://<id>`; the
    session-lifecycle skill's name line; session-isolation rule's
    BufReadCmd exception (now also resolves names).
13. Tests (TDD, first): `format(parse(n)) == n` for chat, transcript,
    panel, message input, background; `parse` of every `PANELS` value and
    of malformed names; `claim_name` refuses another session's buffer and
    keeps a split's window; BufReadCmd: `:e`, `:sp`, `<C-w>gf` on a saved
    session (mocked transport), a live session's wiped panel and wiped
    transcript, an unknown id, a numeric key, no window (`bufload`),
    `:bd!` of a transcript then reload keeps it, a second `:e` during a
    pending load shows the same chat; `gf` on a fork link name;
    `_session_changed` renames panels, transcripts, inputs; `gf` on a
    subagent block after `switch_provider` shows its transcript; failed
    `/new` reverts names; completion in the input after a rename;
    `/rename` keeps the chat's name; the permission float title shows the
    label. Update the tests listed under Relevant files.

## Expected outcome

- Session buffers are `agentic://<acp-id>` (chat),
  `agentic://<acp-id>/<sub-id>` (transcript), `agentic://<acp-id>/<panel>`,
  `agentic://<acp-id>/<sub-id>/input`, `agentic://<bg-id>/background`,
  fixed for the life of the ACP session; before it exists,
  `<SessionManager.id>` stands in.
- `:e`, `:sp`, `:tabe`, `gf`, `<C-w>f`, `<C-w>gf` on a chat or transcript
  name show the live buffer, or load the saved session and show it, in the
  window the command chose. A live session's panel name shows that panel.
- Restoring a vim session (`:source Session.vim`) that shows `agentic://`
  windows resumes those chats.
- A fork link row shows the other chat's name; native `gf` follows it with
  the cursor on the name.
- `:ls` and buffer pickers show ids, not titles.
- The fork-specific `gf` code is gone.

## Non-goals

- The header's `#<n>` stays.
- Loading a closed session from a panel name.
- Re-create from history (Path B) giving a chat a new ACP id: a link to
  the old id loads the old saved session, as `resume` does today.
- Placing the cursor on the other chat's link back after `gf`: `:e`
  cannot know the source.
- Hover or a titled peek for a name: the winbar header shows the title.
- Opening a transcript name shows the chat first, then the transcript, in
  that window.

## Open questions

None.
