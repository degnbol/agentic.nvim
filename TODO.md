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

- **Queued message vs auto-continue conflict**: If a message is queued while a
  session is waiting to auto-continue, the back-off retry logic falsely treats
  it as a continue attempt and starts the 5-minute delay. Add support for
  queueing messages while waiting to auto-continue.

- **Fold marker not closed**: Rare issue where a fold marker (`{{{`) is inserted
  but the closing marker (`}}}`) is missing, causing everything from that point
  to the end of the chat buffer to be folded into a single fold.

- **Syntax highlight overflow**: Rare issue where treesitter syntax highlighting
  from a previous block bleeds into the permission prompt, colouring parts of it
  incorrectly.

- ~~Should we consider an /exit command or a keymap to clear up?~~ Done:
  `/delete` slash command deletes the current session from disk and clears the
  UI. Confirmation prompt by default (`session_restore.confirm_delete = true`).