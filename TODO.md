- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- Improve permission checks
  - split on `;` and `&&` and evaluate each part individually
  - allow `> /dev/null`, it's not a dangerous pipe.

- Error display: currently errors are shown inline in the chat buffer with red
  highlighting (AgenticErrorHeading/AgenticErrorBody). A future option could use
  neovim's native error display (vim.notify, vim.diagnostic, or floating window)
  instead of or in addition to the inline chat display. This is a matter of user
  preference — some may want errors in the editor, others in the chat. Could be a
  config toggle (e.g. `error_display = "chat" | "notify" | "both"`).

- extmarks seem more fragile than other approaches. Still need to fix when the 
  chat is updated and all the extmarks gets cleared, plus some rare cases where a 
  final gutter extmark is added twice.

- for the grep/ripgrep search task, we could highlight the line number as Number and the colon right after as Delimiter.
  One non-extmark solution would be to detect that this is grep output, not just generic "console" code block, and then have a syntax/grep.vim with simple regex highlight rules.
  - The grep is not always performed by the search tool, it also is called from the execute tool. This should also be colored.
    - For the execute tool (and maybe the search tool as well?) there might be a `grep ... | head ...` pattern or similar. This should also be supported, that doesn't change the fact that the output is grep format. Same with a grep on a grep or other patterns.

- Investigate streaming performance — large tool call outputs (e.g. long file reads) can cause visible lag when writing to the chat buffer.

- Slim down readme, and remove the contribution markdown file.
  These are currently written for the project we forked from, our readme should 
  reflect our project and how it differs, e.g. claude focus, added formatting and 
  syntax hl.

- Some sessions are more clearly completed than others. If user prompt is last in a session it's not completed. If the session ends in a commit etc. it's probably completed.
  When it is and isn't might be a bit of a heuristic to detect but we could use a specific close keymap (instead of :qa!) to close marking a session for archive.
  Why is this useful? For the resume functionality. So we can easily resume from just the unfinshed work (or choose to look at archive specifically.)