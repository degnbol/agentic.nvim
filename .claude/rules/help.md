---
paths: "doc/*.txt"
---

# Help files

Human-facing `:help` for using and configuring a neovim plugin. That is the
whole subject: requirements, dependencies, setup steps, options, keymaps,
commands, and what setting them does. Not the screen — a reader with the UI in
front of them does not need it described.

Concise. Nobody reads paragraphs to set up a plugin.

It says what a thing is. It does not:

1. advise — no suggesting when a reader might want an option, no reasons for
   or against a setting, no alternatives to consider. List the options; the
   reader chooses.
2. say what something isn't
3. say why something is
4. say how something is

Requirements, dependencies and setup steps are statements of fact, not advice,
and belong here.

Any exception requires express permission.

Also applies here: `docs.md` in this directory, and the global `edit-docs` and
`lang-vimdoc` rules.
