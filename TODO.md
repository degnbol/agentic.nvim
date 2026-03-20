- Looks like we have custom completion in the plugin, e.g. using tab. It should probably just build on top of blink.cmp.
  It currently shows completion for e.g. /context, but if I press <Enter> after writing /context the menu doesn't go away.

- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- In chat: for code blocks with no language indicated, either default to shell or edit claude's output to assign shell to the triple quotes.
 - This might already be happening, it might just be that we don't have any TS for bash. We could use the zsh one.

- :w sends input to claude, but :wq would try to close windows and cause errors.
  Can we safe-guard against this, e.g. use :q! and/or tabclose to end claude session and close all windows.

- Some executions have long console "code" block outputs. Folding could be a vim-native way to hide lines from this, while keeping it available for expansion.

- Improve execute task long one-liners by showing as if multi-line:
  - See if it's possible to find a reliable split on \n when they are not e.g. in a string etc.
  - Could also split by changing e.g. `&&` -> `&& \\n`

- Improve permission checks
  - split on `;` and `&&` and evaluate each part individually
  - allow `> /dev/null`, it's not a dangerous pipe.

- Change all Tasks from read(filename), etc. to read `filename` and only do the background coloring that indicates pending vs completed for the taks name ("read", etc.) and not the whole line.

- When claude is overloaded we get the following written to the chat:
**Error:** {
  code = -32603,
message = 'Internal error: API Error: 529
  {"type":"error","error":{"type":"overloaded_error","message":"Overloaded.
  https://docs.claude.com/en/api/errors"},"request_id":"req_011CZ9Kp7f61eygVGZCcwZ6w"}'
}
Consider formatting this nicer and maybe making it Error red. Try to do that adding some custom treesitter query, or vim syntax regex.

- extmarks seem more fragile than other approaches. We could reduce the use of 
them for e.g. " ✔ completed" which is green bg. It could just be coloured using 
custom TS query or vim syntax regex which would be associated with the 
AgenticChat filetype that extends markdown. Of course this has to be changes in agentic.nvim

- for the grep/ripgrep search task, we could highlight the line number as Number and the colon right after as Delimiter.
  One non-extmark solution would be to detect that this is grep output, not just generic "console" code block, and then have a syntax/grep.vim with simple regex highlight rules.
  - The grep is not always performed by the search tool, it also is called from the execute tool. This should also be colored.
    - For the execute tool (and maybe the search tool as well?) there might be a `grep ... | head ...` pattern or similar. This should also be supported, that doesn't change the fact that the output is grep format. Same with a grep on a grep or other patterns.

- When denying "Switch Mode `Read to Code?`" it shows
```
The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.

Note: The user's next message may contain a correction or preference. Pay close attention — if they explain what went wrong or how they'd prefer you to work, consider saving that to memory for future sessions.
```
This is meant for claude, not the user. Should be suppressed in the chat.

- The AgenticInput should have conceallevel=0, conceallevel>0 was supposed to just be added for AgenticChat and maybe some other Agentic* window types.
