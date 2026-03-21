- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- :w sends input to claude, but :wq would try to close windows and cause errors.
  Can we safe-guard against this, e.g. use :q! and/or tabclose to end claude session and close all windows.

- Improve permission checks
  - split on `;` and `&&` and evaluate each part individually
  - allow `> /dev/null`, it's not a dangerous pipe.

- When claude is overloaded we get the following written to the chat:
**Error:** {
  code = -32603,
message = 'Internal error: API Error: 529
  {"type":"error","error":{"type":"overloaded_error","message":"Overloaded.
  https://docs.claude.com/en/api/errors"},"request_id":"req_011CZ9Kp7f61eygVGZCcwZ6w"}'
}
Consider formatting this nicer and maybe making it Error red. Try to do that adding some custom treesitter query, or vim syntax regex.

- extmarks seem more fragile than other approaches. Still need to fix when the 
  chat is updated and all the extmarks gets cleared, plus some rare cases where a 
  final gutter extmark is added twice.

- for the grep/ripgrep search task, we could highlight the line number as Number and the colon right after as Delimiter.
  One non-extmark solution would be to detect that this is grep output, not just generic "console" code block, and then have a syntax/grep.vim with simple regex highlight rules.
  - The grep is not always performed by the search tool, it also is called from the execute tool. This should also be colored.
    - For the execute tool (and maybe the search tool as well?) there might be a `grep ... | head ...` pattern or similar. This should also be supported, that doesn't change the fact that the output is grep format. Same with a grep on a grep or other patterns.

- Open todo window with a height exactly matching the number of todo items.
