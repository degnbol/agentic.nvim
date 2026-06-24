; inherits markdown

; The MessageWriter encodes its fold decision into the fence info string with a
; "-fold" suffix on the base language (```markdown-fold, ```console-fold). That
; suffix is a fold signal, not a language, so strip it before resolving the
; injected parser — otherwise the sidecar markdown body would lose its markdown
; highlighting (`markdown-fold` is not a parser). gsub is a no-op on fences
; without the suffix, so plain ```python / ```bash blocks inject as before.
;
; Edit diffs carry a "difffold" marker (```lua-difffold) and are deliberately
; EXCLUDED here: injecting the base language ships its folds.scm, whose
; per-structure folds shatter the diff into one fold per function/if/table.
; With no injection the diff folds as one block; highlighting comes from
; block_col_hl extmarks (tool_call_renderer build_highlight_map), which already
; override the injection at priority 200 on any loadable diff.
(fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content
  (#not-lua-match? @injection.language "difffold$")
  (#gsub! @injection.language "%-fold$" ""))
