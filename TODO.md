- **Error display**: Currently errors are shown inline in the chat buffer with
  red highlighting (`AgenticErrorHeading`/`AgenticErrorBody`). A future option
  could use neovim's native error display (`vim.notify`, `vim.diagnostic`, or a
  floating window) instead of or in addition to the inline chat display. This is
  a matter of user preference — some may want errors in the editor, others in
  the chat. Could be a config toggle (e.g.
  `error_display = "chat" | "notify" | "both"`).

- **Streaming performance**: Large tool call outputs (e.g. long file reads) can
  cause visible lag when writing to the chat buffer. Investigate.

- **Session completion heuristic**: Some sessions are more clearly completed
  than others. If the user prompt is last, the session is not completed. If it
  ends in a commit etc., it probably is. Detection is heuristic, but we could
  use a specific close keymap (instead of `:qa!`) to mark a session for archive.
  Useful for resume: easily resume only unfinished work (or browse the archive
  specifically).

- **Fold marker not closed**: Rare issue where a fold marker (`{{{`) is inserted
  but the closing marker (`}}}`) is missing, causing everything from that point
  to the end of the chat buffer to be folded into a single fold.

- **Syntax highlight overflow**: Rare issue where treesitter syntax highlighting
  from a previous block bleeds into the permission prompt, colouring parts of it
  incorrectly.

- TUI parity: provide local intercepts or closest-match implementations for
  TUI commands/features the ACP bridge doesn't expose. See
  |agentic-vs-tui-missing| in `doc/agentic.txt` for the full list
  (`/diff`, `/rewind`, `/branch`, `/teleport`, `/effort`, background jobs)
  plus `/stats` and `/usage`. `/effort` is blocked upstream: claude-agent-acp
  0.29.0 does not emit the `thought_level` ConfigOption; see
  `lua/agentic/acp/AGENTS.md` § "`thought_level` ConfigOption not emitted
  (claude-agent-acp)". `/permissions` has no ACP surface and is out of scope.

- Info keymap opening a window with session info: model, context use, prompt
  count, proximity to limits. Freer format than the slash commands since it's
  not bound to TUI parity.

- In some cases with the Edit tool used on a script the script might not have a
  file extension but still has a shebang (or even a vim modeline) indicating
  filetype. Should we support this as well in chat when displaying the code
  injection preview? It's not a common case.

- In some cases md formatting leaks from chat blocks since we are often writing
  directly to chat without protection, e.g. I can write `##` in a prompt and that
  way inject a block directly. Same happens with colors breaking in rare cases
  from the ACP's side. So the fix: I think we need to either always put the
  contents in a proteced block, or detect special characters before pasting in
  chat and then protect more targeted.

- For proper sharing of this plugin we need to see it in action with nvim --clean plus plugin.

- We need gifs in the readme or elsewhere demoing the differences between this plugin and the stock TUI.

- Manual code review, this repo is heavily vibe-coded.

- Queing a message doesn't work while waiting for a slow resume.

- Long Edit tool previews needs folding mechanism. E.g. not folded by default but zc works.

- Ctrl-c doesn't work as intended. While claude is writing prose to chat it
  works great: it stops claude completely. While claude prompts for allow for
  editing a file, ctrl-c rejects, but then claude will start thinking and does a
  dumb response saying "I was trying to do x and since I couldn't here's the
  instructions for you to do it". Intended behaviour: ctrl-c stops and blocks claude fully
  in all scenarios (but not persistent stopping based on task etc.).
  The numbered options are for other reject behaviours.

- In the original agentic.nvim before forking there was a window for listing edited files.
  I removed this to save screen space, there might be relevant code still
  around, otherwise there would be code for inspiration in the forked repo. To
  still save space it can be removed with the usual :q and accessed with a
  localLeader keymap.
  I think it could be useful to have an improved version, by taking advantage of
  other work we have done for tracking line range edits by claude vs other for
  each file. A quickfix menu might be useful, but I wonder about having that
  while we also use it for resume. And if there's multiple edits in a file the qf
  would have to have multiple entries per file.

- Opening a file in neovim allows for undo since we have persistent undo file.
  Could we (optionally) integrate this plugin with that? So a user can go through the edit history from claude with u.

- resume right after compacting doesn't show history from before compacting, just the compacting summary. Both would be ideal.

- Does the /trust system work with the glob pattern using ~/, relative and abs folders?

- Allow for queing commands, e.g. `/compact\nContinue` should fire `/compact`
  correctly (it doesn't), and then fire `Continue` when compaction is complete.
  Essentially work as if user prompts `/compact` and then a moment later the rest.

- Markdown table column alignment has a subtle misalignment issue. If the whole
  table is visible in the width of the chat buffer it looks fine, but if the
  table is wider and we scroll sideways only showing part of the table AND
  there's conceal involved on a row the columns gets slightly misaligned *as we
  scroll* since the conceal with conceallevel=2 hides e.g. ticks `...`, but when
  we scroll and they are out of view they are not concealed (removed) anymore.
  I'm not sure if there is a fix besides using conceallevel=1. Have some
  elaborate autocommand that updates the visual on scroll events would be
  overkill. There might be some extmark/virtual text tricks that can help.

- Writing /trust heree (typo) goes through. Maybe just adding completion would help?
