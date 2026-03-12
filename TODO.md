- Running /context doesn't show anything in the chat window
  - Investigated: the ACP prompt response is empty (just stopReason + zero usage).
    /context output isn't proper json so is dropped. Working on supporting non-json.

- Would be cool to add syntax highlighting to the permission commands

- No warning in our plugin about context filling up.
  Instead of a warning maybe we could always show the percentage, e.g. like "Claude Default 35%"

- Do we have custom completion in the plugin? It should probably just build on top of blink.cmp.
  It currently shows completion for e.g. /context, but if I press <Enter> after writing /context the menu doesn't go away.
