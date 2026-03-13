- Do we have custom completion in the plugin? It should probably just build on top of blink.cmp.
  It currently shows completion for e.g. /context, but if I press <Enter> after writing /context the menu doesn't go away.

- When making new files a new tab is opened with that file, which is fine but I 
  get a warning that a buffer with no window is created. When switching to it there's another warning with options [O]k, [L]oad, ...

- In chat: for code blocks with no language indicated, either default to shell or edit claude's output to assign shell to the triple quotes.

- Messages don't seem to be queued properly while compacting

- The formatting that hard wraps line of prose needs to take into account the gutter adds a little width.

- :w sends input to claude, but :wq would try to close windows and cause errors.
  Can we safe-guard against this, e.g. use :q! and/or tabclose to end claude session and close all windows.
