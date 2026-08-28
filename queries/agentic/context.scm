; treesitter-context breadcrumbs for the chat buffer's section tree.
;
; Both captures guard on `(atx_heading (inline))` — an empty ATX heading has NO
; inline child, so the empty `###` boundary the MessageWriter emits before
; resumed prose is never captured. That boundary closes the preceding tool
; section (markdown has no section-close token), letting the walk fall through
; to the `## prompt` heading instead of pinning a stale filename.
;
; Under the plugin's `max_lines = 1` + `trim_scope = 'outer'` config the
; innermost matching ancestor wins: inside a tool-call diff both the `###`
; filename section and the enclosing `## prompt` match, so the filename pins;
; in post-tool summary / intro prose only `## prompt` matches, so the prompt
; pins. Injected languages pin their own function/class context independently.

; Non-empty fence-bearing sections — the collapsed tool-call heads
; (`` ### `name` ``), whose diff/output fence is what scrolls. The kind glyph is
; a sign-column extmark and cannot reach the breadcrumb, so a pinned head shows
; the name alone.
(section
  (atx_heading (inline))
  (fenced_code_block)) @context

; The non-empty `## prompt` section — pins the prompt when it is the only
; matching ancestor.
(section
  (atx_heading
    (atx_h2_marker)
    (inline))) @context
