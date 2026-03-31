- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- Error display: currently errors are shown inline in the chat buffer with red
  highlighting (AgenticErrorHeading/AgenticErrorBody). A future option could use
  neovim's native error display (vim.notify, vim.diagnostic, or floating window)
  instead of or in addition to the inline chat display. This is a matter of user
  preference — some may want errors in the editor, others in the chat. Could be a
  config toggle (e.g. `error_display = "chat" | "notify" | "both"`).

- extmarks seem more fragile than other approaches. Still need to fix when the 
  chat is updated and all the extmarks gets cleared, plus some rare cases where a 
  final gutter extmark is added twice.

- Investigate streaming performance — large tool call outputs (e.g. long file reads) can cause visible lag when writing to the chat buffer.

- Some sessions are more clearly completed than others. If user prompt is last in a session it's not completed. If the session ends in a commit etc. it's probably completed.
  When it is and isn't might be a bit of a heuristic to detect but we could use a specific close keymap (instead of :qa!) to close marking a session for archive.
  Why is this useful? For the resume functionality. So we can easily resume from just the unfinshed work (or choose to look at archive specifically.)
