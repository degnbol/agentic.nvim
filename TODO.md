- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- :w sends input to claude, but :wq would try to close windows and cause errors.
  Can we safe-guard against this, e.g. use :q! and/or tabclose to end claude session and close all windows.

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

- We have a claude hook that rings a bell when claude is done thinking. In this ACP wrapper project, could we have a similar simpler implementation? Then a user can opt-in to that in their config without having to set up their own hook like we have done.

- Investigate streaming performance — large tool call outputs (e.g. long file reads) can cause visible lag when writing to the chat buffer.

