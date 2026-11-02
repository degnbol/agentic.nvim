---
paths: "doc/*.txt"
---

# Help files

Human-facing `:help` for using and configuring a neovim plugin: requirements,
dependencies, setup steps, options, keymaps, commands, and what setting them
does. It says what a thing is, at the level a user meets it.

Concise. Nobody reads paragraphs to set up a plugin.

It does not:

1. advise — no suggesting when a reader might want an option, no reasons for
   or against a setting, no alternatives to consider. List the options; the
   reader chooses.
2. say what something isn't
3. say why something is
4. describe mechanism — how the plugin does it, or how each case or code path
   behaves. That is docstring content.
5. describe the screen — a reader with the UI in front of them sees it.
6. restate neovim's own help — link the `|tag|` and state only what the plugin
   adds.

Any exception requires express permission.

Also applies here: the global `edit-docs` and `lang-vimdoc` rules.
