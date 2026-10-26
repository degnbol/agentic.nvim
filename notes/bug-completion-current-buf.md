# Bug: input completion reads the current buffer after a schedule

Found by a read-only audit (2026-10-26); not reproduced.

## Observed in code
`lua/agentic/completion/lsp_server.lua` (completion handler, around :300-320): the handler schedules its work, then reads `nvim_get_current_buf()` and the cursor line instead of the buffer named by the request's `textDocument.uri`. If focus moves between the request and the scheduled callback, completion is computed for the wrong buffer. The `#lines == 0` guard at :314-317 exists for the same window.

## Expected
The handler resolves the buffer from the request (`vim.uri_to_bufnr`) and the position from the request's `position`.
