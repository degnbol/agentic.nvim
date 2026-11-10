; The chat buffer parses as the private `agentic` language (a clone of the
; markdown parser) so its folds query is isolated from real markdown buffers.
; The chat's highlighter gets this query without its conceal_lines metadata
; (see `agentic.ui.FenceRows`).
; inherits markdown
