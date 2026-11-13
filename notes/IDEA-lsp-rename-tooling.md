# Idea: LSP rename and lookup tools for the agent

If claude is refactoring, e.g. renaming all occurrences of a variable it essentially does a search/replace plus looking at context around word to understand.
Why not rename like I would in the editor using the LSP?
The LSP is often a program that can be run from the shell, it's almost a CLI, but not quite.
I think we should be able to write some thin wrapper around LSPs to call them like CLIs (like `lsp rename <old name, row and col?> <new name> <filename>`) that then writes a bit of json(?) boilerplate and sends it to based-pyright if `<filename>` is python etc.

cclsp (MCP) rename, `find_references`, `find_implementation` and `get_incoming_calls` are denied
in `~/.config/claude/settings.json`: cclsp uses the session cwd as the workspace root for every
file (results outside it miss other files), a lookup by name on a Lua `Foo:method` targets `Foo`,
and `rename_symbol_strict` takes a bare line/column, so one column off renames `Foo` without
saying so. Brainstorm LSP tools that avoid all three, e.g.:

- headless nvim calling `vim.lsp.buf.rename` (or `textDocument/rename` via `vim.lsp`) — reuses
  the real per-file root detection and server config; take the old name as well as the position
  and refuse when the identifier there differs; print the edits per file.
- agentic.nvim could expose the running nvim's LSP clients to the agent instead (already
  attached, already indexed).
