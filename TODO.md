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

- Support for the claude TUI `/effort`. E.g. a localLeader keymap opening a
  select menu. Also showing effort somewhere on screen. Blocked:
  claude-agent-acp 0.29.0 does not emit the `thought_level` ConfigOption.
  See `lua/agentic/acp/AGENTS.md` § "`thought_level` ConfigOption not emitted
  (claude-agent-acp)".

- Slash commands `/stats` and `/usage` — intercepted locally and formatted to
  match the TUI's output as closely as possible, for users moving between the
  two seamlessly.

- Info keymap opening a window with session info: model, context use, prompt
  count, proximity to limits. Freer format than the slash commands since it's
  not bound to TUI parity.